import AVFoundation
import Foundation

/// Finds moments in a recording made elsewhere: a wireless pin mic, Voice Memos, or the sound of a video.
/// Two passes, so a long recording never sits in memory: listen once, then cut out only the chosen moments.
final class FileImporter: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var message: String?
    @Published private(set) var lastCount = 0

    enum ImportError: Error { case noAudio, unreadable }

    struct Clip {
        let samples: [Float]
        let offset: Double
        let tag: MomentTag
        let score: Double
    }

    func run(url: URL, store: MomentStore, settings: AppSettings) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        message = "音を読み込んでいます…"
        let sensitivity = settings.sensitivity, length = settings.lengthSeconds, cap = settings.dailyCap
        Task.detached(priority: .userInitiated) { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            do {
                let (total, clips) = try await FileImporter.find(url: url, sensitivity: sensitivity, lengthSeconds: length, cap: cap) { p, heard in
                    DispatchQueue.main.async {
                        self?.progress = p
                        self?.message = "耳をすませています… " + Format.duration(heard)
                    }
                }
                // the file's date is when the recording ended
                let base = fileDate.addingTimeInterval(-total)
                await MainActor.run {
                    var saved = 0
                    for c in clips {
                        let m = store.add(samples: c.samples, date: base.addingTimeInterval(c.offset), tag: c.tag, score: c.score,
                                          dailyCap: cap, sourceFile: url.lastPathComponent)
                        if m != nil { saved += 1 }
                    }
                    self?.progress = 1
                    self?.message = saved > 0
                        ? Format.duration(total) + "の音から、\(saved)つの瞬間を拾いました。時刻はファイルの日時から推定しています。"
                        : Format.duration(total) + "の音を聴きましたが、拾える瞬間は見つかりませんでした。「せってい」で感度を上げると拾いやすくなります。"
                    self?.lastCount = saved
                    self?.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self?.message = "このファイルは読み込めませんでした。音声ファイル（m4a・mp3・wav）か、動画（mp4・mov）を選んでください。"
                    self?.isRunning = false
                }
            }
        }
    }

    /// Same rules as the live listener. Keeps at most two moments per minute of recording (at least 3, at most the daily cap).
    static func find(url: URL, sensitivity: Sensitivity, lengthSeconds: Int, cap: Int,
                     progress: @escaping (Double, Double) -> Void) async throws -> (total: Double, clips: [Clip]) {
        let sr = Detector.sampleRate
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.noAudio }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let estimate = max(1, seconds.isFinite ? seconds * Double(sr) : 1)

        // pass 1: listen
        let detector = Detector(sensitivity: sensitivity)
        let grouper = Grouper(lengthSeconds: lengthSeconds)
        var caps: [Grouper.Capture] = []
        var pos = 0, reported = 0
        try read(asset: asset, track: track) { chunk in
            for ev in detector.feed(chunk) { grouper.event(ev, minStart: 0) }
            pos += chunk.count
            caps += grouper.advance(to: pos)
            if pos - reported >= sr * 20 {
                reported = pos
                progress(min(0.95, Double(pos) / estimate), Double(pos) / Double(sr))
            }
        }
        caps += grouper.flush(at: pos)
        let total = pos
        let minutes = Int((Double(total) / Double(sr) / 60).rounded(.up))
        let limit = max(3, min(cap, minutes * 2))
        let chosen = caps.filter { min($0.end, total) - $0.start >= sr * 2 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .sorted { $0.start < $1.start }
        if chosen.isEmpty { return (Double(total) / Double(sr), []) }

        // pass 2: cut out only the chosen moments
        var buffers = chosen.map { [Float](repeating: 0, count: min($0.end, total) - $0.start) }
        var at = 0
        try read(asset: asset, track: track) { chunk in
            let a = at, b = at + chunk.count
            for (k, c) in chosen.enumerated() {
                let s = max(a, c.start), e = min(b, min(c.end, total))
                if s < e { for i in s..<e { buffers[k][i - c.start] = chunk[i - a] } }
            }
            at = b
        }
        let clips = chosen.enumerated().map { k, c in
            Clip(samples: buffers[k], offset: Double(c.start) / Double(sr), tag: c.type, score: c.score)
        }
        return (Double(total) / Double(sr), clips)
    }

    /// Decodes the audio track as mono 24 kHz float samples, chunk by chunk.
    private static func read(asset: AVAsset, track: AVAssetTrack, _ body: ([Float]) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(Detector.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ImportError.unreadable }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            if count == 0 { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ImportError.unreadable }
            try body(chunk)
        }
        if reader.status == .failed { throw reader.error ?? ImportError.unreadable }
    }
}
