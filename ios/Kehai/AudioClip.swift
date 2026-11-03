import AVFoundation
import Foundation

/// How a moment is written to disk: evened-out loudness, short fades, AAC (m4a).
/// A 20 s clip is about 1 MB as 16-bit WAV and roughly a tenth of that as 48 kbps AAC.
enum AudioClip {
    static let bitRate = 48_000

    /// Raises quiet clips so they play back at a comfortable level (peak at -1 dBFS, at most +30 dB),
    /// then fades the ends so they don't click. Only the volume changes; nothing is filtered.
    static func prepare(_ input: [Float], fade: Bool = true) -> [Float] {
        var x = input
        var peak: Float = 0
        for v in x { peak = max(peak, abs(v)) }
        if peak > 1e-5 {
            let target: Float = 0.891 // -1 dBFS
            let gain = min(target / peak, 31.6) // +30 dB at most
            if gain > 1 { for i in 0..<x.count { x[i] *= gain } }
        }
        let fadeN = fade ? min(Int(0.25 * Double(Detector.sampleRate)), x.count >> 2) : 0
        if fadeN > 0 {
            for i in 0..<fadeN {
                let g = Float(i) / Float(fadeN)
                x[i] *= g
                x[x.count - 1 - i] *= g
            }
        }
        return x
    }

    /// Writes `baseName.m4a` (or `.wav` if AAC isn't available) in `folder`; returns the file name.
    static func write(_ x: [Float], in folder: URL, baseName: String) -> String? {
        let name = freeName(in: folder, baseName: baseName, ext: "m4a")
        if writeAAC(x, to: folder.appendingPathComponent(name)) { return name }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        let wavName = freeName(in: folder, baseName: baseName, ext: "wav")
        do {
            try WAV.encode(x, fade: false).write(to: folder.appendingPathComponent(wavName), options: .atomic)
            return wavName
        } catch { return nil }
    }

    private static func freeName(in folder: URL, baseName: String, ext: String) -> String {
        var name = "\(baseName).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(baseName)_\(n).\(ext)"
            n += 1
        }
        return name
    }

    private static func writeAAC(_ x: [Float], to url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(Detector.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Detector.sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, x.count))),
              let ch = buffer.floatChannelData else { return false }
        buffer.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { ch[0].update(from: base, count: x.count) }
        }
        do {
            // the file is closed (and the AAC stream finished) when `file` goes out of scope
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch { return false }
        return true
    }

    /// Reads any clip the app saved (WAV or m4a) as mono floats at 24 kHz.
    static func read(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let ch = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength), channels = Int(format.channelCount)
        var out = [Float](repeating: 0, count: n)
        for c in 0..<channels { for i in 0..<n { out[i] += ch[c][i] / Float(channels) } }
        if Int(format.sampleRate) != Detector.sampleRate {
            out = LinearResampler(inputRate: format.sampleRate).process(out)
        }
        return out
    }
}
