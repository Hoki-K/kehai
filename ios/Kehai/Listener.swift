import AVFoundation
import Foundation

/// Listens through the microphone, keeps the last 60 s in memory, and saves only the moments the detector picks.
/// Everything else is overwritten in the ring buffer and never written anywhere.
final class Listener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isInterrupted = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastSaved: Moment?
    @Published var errorMessage: String?

    /// 0...1, read by the ear animation on every frame. Not @Published on purpose: it changes ~12 times a second.
    private(set) var level = 0.0

    private let store: MomentStore
    private let settings: AppSettings
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "kehai.dsp", qos: .userInitiated)
    private var dsp: DSP?
    private var tapInstalled = false
    private var pendingSeconds = 0.0
    private var muted = false
    private var pendingRestart: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(store: MomentStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            self?.handleInterruption(n)
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as AnyObject?) === self.engine else { return }
            self.scheduleRestart()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            // the old engine is no longer usable; start over with a new one
            guard let self else { return }
            let wasListening = self.isListening
            self.stop()
            self.engine = AVAudioEngine()
            if wasListening {
                self.errorMessage = "音のしくみがリセットされたため、止まりました。もう一度「耳をすます」を押してください。"
            }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    static let sessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay, .mixWithOthers]

    // MARK: start / stop

    func start() {
        guard !isListening else { return }
        errorMessage = nil
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.begin() } else {
                    self.errorMessage = "マイクを使えませんでした。「設定」アプリの「けはい」で、マイクをオンにしてください。"
                }
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .default mode: the phone's normal microphone level. (.measurement kept the room "as is" but recorded
            // 20-30 dB too quietly on an iPhone 15 Pro, which also broke the labels.) No echo cancelling either way.
            // No .allowBluetooth (HFP), so AirPods can play music without taking over the microphone.
            try session.setCategory(.playAndRecord, mode: .default, options: Listener.sessionOptions)
            try session.setActive(true)
            applyPreferredInput()
            try startEngine()
        } catch {
            teardownEngine()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = "マイクを開けませんでした。マイクがつながっているか確かめてください。"
            return
        }
        isListening = true
        isInterrupted = false
        startedAt = Date()
    }

    func stop() {
        guard isListening else { return }
        pendingRestart?.cancel()
        pendingRestart = nil
        isListening = false
        isInterrupted = false
        teardownEngine()
        closeDSP()
        flushListening()
        startedAt = nil
        level = 0
        isCapturing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// While a saved moment is playing, the phone would hear itself. Ignore detections until it stops.
    func setMuted(_ on: Bool) {
        muted = on
        queue.async { [dsp] in dsp?.setMuted(on) }
    }

    func applySensitivity(_ s: Sensitivity) {
        queue.async { [dsp] in dsp?.detector.setSensitivity(s) }
    }

    // MARK: inputs (wired / USB pin-mic receivers)

    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        let uid = settings.inputUID
        var port: AVAudioSessionPortDescription?
        if !uid.isEmpty { port = session.availableInputs?.first(where: { $0.uid == uid }) }
        try? session.setPreferredInput(port)
    }

    /// Called from Settings when the user picks another microphone.
    func inputChanged() {
        guard isListening else { return }
        applyPreferredInput()
        // the route change posts AVAudioEngineConfigurationChange, which restarts the engine
    }

    // MARK: engine

    private func startEngine() throws {
        if tapInstalled { teardownEngine() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Detector.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw ListenerError.noInput
        }
        converter.downmix = true
        let dsp = DSP(sensitivity: settings.sensitivity, lengthSeconds: settings.lengthSeconds)
        dsp.setMuted(muted)
        self.dsp = dsp
        let tap = Listener.makeTap(dsp: dsp, converter: converter, target: target, queue: queue) { [weak self] out in
            self?.receive(out, from: dsp)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    /// A route change (a receiver plugged in, a new preferred input) can post several notifications in a row.
    /// The engine has already stopped itself; restart it once things have settled.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartEngine() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func restartEngine() {
        pendingRestart = nil
        guard isListening, !isInterrupted else { return }
        teardownEngine()
        closeDSP()
        do { try startEngine() } catch {
            stop()
            errorMessage = "マイクが切り替わったあと、聴き直せませんでした。もう一度「耳をすます」を押してください。"
        }
    }

    private func handleInterruption(_ n: Notification) {
        guard isListening, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // a phone call or another app took the microphone
            teardownEngine()
            closeDSP()
            isInterrupted = true
            isCapturing = false
            level = 0
        case .ended:
            guard isInterrupted else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try startEngine()
                isInterrupted = false
            } catch {
                stop()
                errorMessage = "電話などで止まりました。もう一度「耳をすます」を押してください。"
            }
        @unknown default:
            break
        }
    }

    /// Builds the tap outside the class's state so the audio thread only touches the converter and the DSP queue.
    private static func makeTap(dsp: DSP, converter: AVAudioConverter, target: AVAudioFormat, queue: DispatchQueue,
                                deliver: @escaping (DSP.Output) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if given {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channels = out.floatChannelData, out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(out.frameLength)))
            queue.async {
                let result = dsp.process(samples)
                DispatchQueue.main.async { deliver(result) }
            }
        }
    }

    // MARK: results (main thread)

    private func receive(_ out: DSP.Output, from source: DSP) {
        save(out.finished)
        guard source === dsp, isListening else { return }
        level = out.level
        if isCapturing != out.capturing { isCapturing = out.capturing }
        pendingSeconds += Double(out.samples) / Double(Detector.sampleRate)
        if pendingSeconds >= 15 { flushListening() }
    }

    private func closeDSP() {
        guard let old = dsp else { return }
        dsp = nil
        queue.async {
            let finished = old.flush()
            DispatchQueue.main.async { [weak self] in self?.save(finished) }
        }
    }

    private func save(_ finished: [DSP.Finished]) {
        for f in finished {
            if let m = store.add(samples: f.samples, date: f.date, tag: f.tag, score: f.score, dailyCap: settings.dailyCap) {
                lastSaved = m
            }
        }
    }

    private func flushListening() {
        store.addListening(seconds: pendingSeconds)
        pendingSeconds = 0
    }

    /// Listening time not yet written to the store (for the "today" counter).
    var unsavedListeningSeconds: Double { pendingSeconds }
}

enum ListenerError: Error { case noInput }

/// Runs on the DSP queue only.
final class DSP {
    struct Finished {
        let samples: [Float]
        let date: Date
        let tag: MomentTag
        let score: Double
    }

    struct Output {
        let level: Double
        let capturing: Bool
        let samples: Int
        let finished: [Finished]
    }

    let detector: Detector
    private let grouper: Grouper
    private let ringSize = Detector.sampleRate * 60
    private var ring: [Float]
    private var position = 0
    private var muted = false
    private var mutedUntil = 0

    init(sensitivity: Sensitivity, lengthSeconds: Int) {
        detector = Detector(sensitivity: sensitivity)
        grouper = Grouper(lengthSeconds: lengthSeconds)
        ring = [Float](repeating: 0, count: Detector.sampleRate * 60)
    }

    func setMuted(_ on: Bool) {
        muted = on
        // keep ignoring for a second after playback ends (the speaker's tail)
        if !on { mutedUntil = position + Detector.sampleRate }
    }

    func process(_ x: [Float]) -> Output {
        let L = ringSize
        for i in 0..<x.count { ring[(position + i) % L] = x[i] }
        let events = detector.feed(x)
        position += x.count
        if !muted && position >= mutedUntil {
            let minStart = max(0, position - L + Detector.sampleRate)
            for ev in events { grouper.event(ev, minStart: minStart) }
        }
        let done = grouper.advance(to: position)
        return Output(level: detector.level, capturing: grouper.current != nil, samples: x.count, finished: done.compactMap(extract))
    }

    func flush() -> [Finished] {
        grouper.flush(at: position).compactMap(extract)
    }

    private func extract(_ c: Grouper.Capture) -> Finished? {
        let L = ringSize
        let start = max(c.start, position - L), end = min(c.end, position)
        guard end - start >= Detector.sampleRate * 2 else { return nil }
        var x = [Float](repeating: 0, count: end - start)
        for i in 0..<x.count { x[i] = ring[(start + i) % L] }
        let date = Date().addingTimeInterval(-Double(position - start) / Double(Detector.sampleRate))
        return Finished(samples: x, date: date, tag: c.type, score: c.score)
    }
}
