import Foundation
import SoundAnalysis
import Speech

/// Work done after a moment is saved, one clip at a time and off the main thread. Everything stays on the phone.
/// 1. clips saved by older versions as WAV are re-saved as AAC (about a tenth of the size, evened-out volume)
/// 2. Apple's built-in sound classifier relabels the clip (laugh / song / talk / shout / crying)
/// 3. on-device speech recognition writes down what was said
final class Enricher: ObservableObject {
    @Published private(set) var isWorking = false

    private let store: MomentStore
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "kehai.enrich", qos: .utility)
    private var attempted: Set<String> = [] // "<id>/<step>" tried during this run of the app
    private var running = false
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    init(store: MomentStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    private enum Step: String { case convert, classify, transcribe }

    /// Call whenever there may be new work (a moment was saved, the app came to the front, a setting changed).
    func kick() {
        guard !running else { return }
        guard let job = nextJob() else {
            if isWorking { isWorking = false }
            return
        }
        let (m, step) = job
        running = true
        if !isWorking { isWorking = true }
        attempted.insert("\(m.id)/\(step.rawValue)")
        let next: () -> Void = { [weak self] in
            self?.running = false
            self?.kick()
        }
        switch step {
        case .convert: convert(m, then: next)
        case .classify: classify(m, then: next)
        case .transcribe: transcribe(m, then: next)
        }
    }

    private func nextJob() -> (Moment, Step)? {
        let speechOK = settings.transcribe && SFSpeechRecognizer.authorizationStatus() != .denied
            && SFSpeechRecognizer.authorizationStatus() != .restricted
        for m in store.moments.sorted(by: { $0.date > $1.date }) {
            func untried(_ s: Step) -> Bool { !attempted.contains("\(m.id)/\(s.rawValue)") }
            if m.fileName.hasSuffix(".wav") && untried(.convert) { return (m, .convert) }
            if m.classified != true && untried(.classify) { return (m, .classify) }
            if speechOK && m.transcript == nil && untried(.transcribe) { return (m, .transcribe) }
        }
        return nil
    }

    // MARK: 1. WAV -> AAC

    private func convert(_ m: Moment, then next: @escaping () -> Void) {
        let folder = store.folder, old = store.url(for: m)
        let base = (m.fileName as NSString).deletingPathExtension
        queue.async { [weak self] in
            var result: (name: String, peaks: [Double])?
            if let x = AudioClip.read(old) {
                let y = AudioClip.prepare(x, fade: false) // the WAV already has its fades
                if let name = AudioClip.write(y, in: folder, baseName: base), name.hasSuffix(".m4a") {
                    result = (name, WAV.peaks(y))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let r = result {
                    self.store.update(m.id) {
                        $0.fileName = r.name
                        $0.peaks = r.peaks
                    }
                    try? FileManager.default.removeItem(at: old)
                }
                next()
            }
        }
    }

    // MARK: 2. sound classifier

    /// Identifiers from Apple's built-in classifier (SNClassifierIdentifier.version1) for each kind of moment.
    static let groups: [MomentTag: [String]] = [
        .laugh: ["laughter", "baby_laughter", "belly_laugh", "chuckle_chortle", "giggling"],
        .sing: ["singing", "choir_singing", "humming", "yodeling"],
        .chat: ["speech", "babble", "whispering"],
        .shout: ["shout", "yell", "screaming", "children_shouting"],
        .cry: ["crying_sobbing", "baby_crying"],
    ]

    /// A laugh or a song lasts a few seconds inside a 20 s clip full of talking, so the strongest seconds count,
    /// and the special kinds win over plain talk when they are clearly there. Tuned by hand; check against real clips.
    static func pick(_ scores: [String: Double]) -> MomentTag? {
        func score(_ t: MomentTag) -> Double { (groups[t] ?? []).map { scores[$0] ?? 0 }.max() ?? 0 }
        let special: [MomentTag] = [.laugh, .sing, .shout, .cry]
        if let best = special.max(by: { score($0) < score($1) }), score(best) >= 0.4 { return best }
        if score(.chat) >= 0.3 { return .chat }
        return nil
    }

    private func classify(_ m: Moment, then next: @escaping () -> Void) {
        let url = store.url(for: m)
        queue.async { [weak self] in
            let scores = SoundTagger.scores(url: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.update(m.id) { moment in
                    moment.classified = true
                    if let scores {
                        moment.sounds = Dictionary(uniqueKeysWithValues: scores.sorted { $0.value > $1.value }.prefix(6).map {
                            ($0.key, ($0.value * 100).rounded() / 100)
                        })
                        if moment.labelByUser != true, let tag = Enricher.pick(scores) { moment.tag = tag }
                    }
                }
                next()
            }
        }
    }

    // MARK: 3. speech to text

    private func transcribe(_ m: Moment, then next: @escaping () -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.attempted.remove("\(m.id)/\(Step.transcribe.rawValue)")
                    next()
                }
            }
            return
        case .authorized:
            break
        default:
            next()
            return
        }
        // only on the phone: if Japanese can't be recognised on this device, we don't send the voice anywhere
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), r.isAvailable, r.supportsOnDeviceRecognition else {
            next()
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: store.url(for: m))
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        recognizer = r
        var finished = false
        let finish: (String?) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, !finished else { return }
                finished = true
                self.task = nil
                if let text { self.store.update(m.id) { $0.transcript = text } }
                next()
            }
        }
        task = r.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                finish(result.bestTranscription.formattedString)
            } else if let error = error as NSError? {
                // 1110: no speech found. Anything else: leave it and try again the next time the app starts.
                finish(error.code == 1110 ? "" : nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard !finished else { return }
            self?.task?.cancel()
            finish(nil)
        }
    }
}

/// Runs SNClassifySoundRequest over a whole clip. For each class: the mean of its three strongest windows (~1 s each).
final class SoundTagger: NSObject, SNResultsObserving {
    private var windows: [String: [Double]] = [:]

    static func scores(url: URL) -> [String: Double]? {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        let observer = SoundTagger()
        do { try analyzer.add(request, withObserver: observer) } catch { return nil }
        analyzer.analyze() // synchronous
        guard !observer.windows.isEmpty else { return nil }
        return observer.windows.mapValues { v in
            let top = v.sorted(by: >).prefix(3)
            return top.reduce(0, +) / Double(top.count)
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        for c in r.classifications { windows[c.identifier, default: []].append(c.confidence) }
    }
}
