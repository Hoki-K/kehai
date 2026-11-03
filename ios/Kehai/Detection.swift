import Foundation

// Port of the detector in web/kehai.html. Keep the two in step: the same rules and the same numbers,
// so a recording picks the same moments on the web and on the phone.
// Foundation only, so ios/Tools/main.swift can compile it on a Mac without the app.

enum MomentTag: String, Codable, CaseIterable {
    case laugh, sing, chat, shout
    /// only from Apple's sound classifier (the rule-based detector never says "cry")
    case cry

    var label: String {
        switch self {
        case .laugh: return "笑い声"
        case .sing: return "うた"
        case .chat: return "おしゃべり"
        case .shout: return "大きな声"
        case .cry: return "泣き声"
        }
    }
}

struct Detection {
    let type: MomentTag
    let score: Double
    var at: Int // absolute sample index (at 24 kHz) where the analysis window ended
}

enum Sensitivity: String, CaseIterable, Codable {
    case low, mid, high
    var multiplier: Double { self == .low ? 1.12 : (self == .high ? 0.86 : 1.0) }
    var label: String { self == .low ? "控えめ" : (self == .high ? "たくさん" : "ふつう") }
}

final class Detector {
    static let sampleRate = 24000
    static let hop = 512
    static let windowSize = 1024
    static let baseThreshold = 0.7

    private var window = [Float](repeating: 0, count: Detector.windowSize)
    private var queue = [Float](repeating: 0, count: Detector.hop)
    private var queued = 0
    private(set) var frames = 0

    private var noiseFloor: Double?
    private let historySize = 256
    private var head = 0
    private var count = 0
    private var rel: [Double]
    private var f0: [Double]
    private var conf: [Double]
    private var voiced: [UInt8]
    private var decimated = [Double](repeating: 0, count: Detector.windowSize / 2)
    private var autocorr = [Double](repeating: 0, count: 120)

    private(set) var threshold = Detector.baseThreshold
    /// 0...1, smoothed loudness above the room's noise floor (for the "ear" animation)
    private(set) var level = 0.0
    /// running estimate of this child's usual voice level above the floor
    private var voiceRef = 18.0

    init(sensitivity: Sensitivity = .mid) {
        rel = [Double](repeating: 0, count: historySize)
        f0 = [Double](repeating: 0, count: historySize)
        conf = [Double](repeating: 0, count: historySize)
        voiced = [UInt8](repeating: 0, count: historySize)
        setSensitivity(sensitivity)
    }

    func setSensitivity(_ s: Sensitivity) { threshold = Detector.baseThreshold * s.multiplier }

    /// Feed mono 24 kHz samples; returns the detections that crossed the threshold.
    func feed<C: Collection>(_ samples: C) -> [Detection] where C.Element == Float {
        var out: [Detection] = []
        let hop = Detector.hop, win = Detector.windowSize
        for s in samples {
            queue[queued] = s
            queued += 1
            if queued == hop {
                // slide the window by one hop
                for i in 0..<(win - hop) { window[i] = window[i + hop] }
                for i in 0..<hop { window[win - hop + i] = queue[i] }
                queued = 0
                frames += 1
                if frames >= 2, var d = step() {
                    d.at = frames * hop
                    out.append(d)
                }
            }
        }
        return out
    }

    // MARK: per-frame analysis

    private func analyze() -> (rel: Double, f0: Double, conf: Double) {
        let n = Detector.windowSize
        var mean = 0.0
        for v in window { mean += Double(v) }
        mean /= Double(n)
        var energy = 0.0
        for v in window { let d = Double(v) - mean; energy += d * d }
        let db = 10 * log10(energy / Double(n) + 1e-12)
        if let fl = noiseFloor {
            noiseFloor = db < fl ? fl + (db - fl) * 0.1 : fl + (db - fl) * 0.004
        } else {
            noiseFloor = db
        }
        if noiseFloor! < -90 { noiseFloor = -90 }
        let r = db - noiseFloor!

        var pitch = 0.0, confidence = 0.0
        if r > 5 {
            let half = n / 2
            var e2 = 0.0
            for j in 0..<half {
                let v = (Double(window[2 * j]) + Double(window[2 * j + 1])) * 0.5 - mean
                decimated[j] = v
                e2 += v * v
            }
            if e2 > 1e-10 {
                let minL = 13, maxL = 110
                var best = 0.0
                for lag in minL...maxL {
                    var acc = 0.0
                    for j in 0..<(half - lag) { acc += decimated[j] * decimated[j + lag] }
                    let nr = acc / (e2 * Double(half - lag) / Double(half))
                    autocorr[lag] = nr
                    if nr > best { best = nr }
                }
                if best > 0.3 {
                    for lag in (minL + 1)..<maxL where autocorr[lag] >= best * 0.9 && autocorr[lag] >= autocorr[lag - 1] && autocorr[lag] >= autocorr[lag + 1] {
                        pitch = Double(Detector.sampleRate / 2) / Double(lag)
                        confidence = autocorr[lag]
                        break
                    }
                }
            }
        }
        return (r, pitch, confidence)
    }

    private func push(_ a: (rel: Double, f0: Double, conf: Double)) {
        rel[head] = a.rel
        f0[head] = a.f0
        conf[head] = a.conf
        let v: UInt8 = (a.conf >= 0.45 && a.rel >= 6 && a.f0 > 0) ? 1 : 0
        voiced[head] = v
        if v == 1 { voiceRef += (a.rel - voiceRef) * 0.01 }
        head = (head + 1) % historySize
        count += 1
    }

    private func last<T>(_ arr: [T], _ n: Int) -> [T] {
        (0..<n).map { arr[(head - n + $0 + historySize * 2) % historySize] }
    }

    private func step() -> Detection? {
        let a = analyze()
        push(a)
        level += (max(0, min(1, a.rel / 30)) - level) * 0.25
        if count < 30 { return nil }
        let scores: [(MomentTag, Double)] = [(.laugh, laugh()), (.sing, sing()), (.chat, chat()), (.shout, shout())]
        var bestTag: MomentTag?
        var bestScore = 0.0
        for (t, s) in scores where s > bestScore { bestScore = s; bestTag = t }
        guard let tag = bestTag, bestScore >= threshold else { return nil }
        return Detection(type: tag, score: bestScore, at: 0)
    }

    private func median(_ v: [Double]) -> Double {
        if v.isEmpty { return 0 }
        let s = v.sorted()
        return s[s.count >> 1]
    }

    // MARK: the four kinds of moment

    /// "ha-ha-ha": five or more pulses at an even 130-320 ms spacing, at a similar pitch
    private func laugh() -> Double {
        let n = min(count, 103)
        if n < 60 { return 0 }
        let r = last(rel, n), vo = last(voiced, n), f = last(f0, n)
        var e = [Double](repeating: 0, count: n)
        for i in 0..<n { e[i] = (r[max(0, i - 1)] + r[i] + r[min(n - 1, i + 1)]) / 3 }
        var peaks: [Int] = []
        var minSince = Double.infinity
        if n > 4 {
            for i in 2..<(n - 2) {
                if e[i] < minSince { minSince = e[i] }
                if e[i] >= 9 && e[i] >= e[i - 1] && e[i] >= e[i + 1] && e[i] >= e[i - 2] && e[i] >= e[i + 2] && e[i] - minSince >= 5 {
                    if let lp = peaks.last, i - lp < 4 { continue }
                    peaks.append(i)
                    minSince = e[i]
                }
            }
        }
        if peaks.count < 5 { return 0 }
        var bestChain: [Int] = []
        var chain = [peaks[0]]
        for k in 1..<peaks.count {
            let d = peaks[k] - peaks[k - 1]
            if d >= 6 && d <= 15 { chain.append(peaks[k]) } else {
                if chain.count > bestChain.count { bestChain = chain }
                chain = [peaks[k]]
            }
        }
        if chain.count > bestChain.count { bestChain = chain }
        let p = bestChain.count
        if p < 5 { return 0 }
        var iv: [Double] = []
        for k in 1..<p { iv.append(Double(bestChain[k] - bestChain[k - 1])) }
        let mean = iv.reduce(0, +) / Double(iv.count)
        let sd = sqrt(iv.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(iv.count))
        let cv = sd / mean
        if cv > 0.28 { return 0 }
        var voicedPeaks = 0
        var loud = 0.0
        var fs: [Double] = []
        var pf: [Double] = []
        for pk in bestChain {
            loud += e[pk]
            var local: [Double] = []
            for j in max(0, pk - 2)...min(n - 1, pk + 2) where vo[j] == 1 { local.append(f[j]) }
            if !local.isEmpty { voicedPeaks += 1; fs.append(contentsOf: local); pf.append(median(local)) }
        }
        if Double(voicedPeaks) / Double(p) < 0.5 { return 0 }
        let med = median(fs)
        if med < 200 { return 0 }
        let pm = pf.reduce(0, +) / Double(pf.count)
        let pcv = sqrt(pf.reduce(0) { $0 + ($1 - pm) * ($1 - pm) } / Double(pf.count)) / pm
        if pcv > 0.09 { return 0 }
        loud /= Double(p)
        return 0.5 + 0.1 * Double(min(3, p - 5)) + 0.25 * (1 - min(1, cv / 0.28)) + 0.2 * min(1, loud / 24) + (med >= 300 ? 0.1 : 0)
    }

    /// a song: four or more held notes (0.25 s+) at different pitches
    private func sing() -> Double {
        let n = min(count, 188)
        if n < 120 { return 0 }
        let vo = last(voiced, n), f = last(f0, n), c = last(conf, n)
        var vcount = 0
        for v in vo { vcount += Int(v) }
        let vf = Double(vcount) / Double(n)
        if vf < 0.45 { return 0 }
        var notes: [(len: Int, med: Double)] = []
        var run: [Double] = []
        func close() {
            if run.count >= 7 {
                let med = median(run)
                var stable = 0
                for v in run where abs(v - med) / med <= 0.04 { stable += 1 }
                if Double(stable) / Double(run.count) >= 0.6 { notes.append((run.count, med)) }
            }
            run = []
        }
        for i in 0..<n {
            if vo[i] == 1 && c[i] >= 0.55 { run.append(f[i]) } else { close() }
        }
        close()
        if notes.count < 4 { return 0 }
        let semis = Set(notes.map { Int((12 * log2($0.med / 440)).rounded()) })
        if semis.count < 2 { return 0 }
        let meanLen = Double(notes.reduce(0) { $0 + $1.len }) / Double(notes.count)
        if meanLen < 12 || vf < 0.55 { return 0 }
        return 0.55 + 0.06 * Double(min(5, notes.count - 4)) + 0.2 * min(1, (meanLen - 12) / 12) + (vf > 0.7 ? 0.1 : 0)
    }

    /// chatter: many short voiced syllables at a child's pitch (median 230 Hz or higher)
    private func chat() -> Double {
        let n = min(count, 234)
        if n < 150 { return 0 }
        let vo = last(voiced, n), f = last(f0, n), r = last(rel, n)
        var vcount = 0, runs = 0, run = 0
        var loud = 0.0
        var fs: [Double] = []
        for i in 0..<n {
            if vo[i] == 1 { vcount += 1; run += 1; fs.append(f[i]); loud += r[i] } else {
                if run >= 3 { runs += 1 }
                run = 0
            }
        }
        if run >= 3 { runs += 1 }
        let vf = Double(vcount) / Double(n)
        if vf < 0.2 || vf > 0.8 || runs < 8 { return 0 }
        let med = median(fs)
        if med < 230 { return 0 }
        if loud / Double(vcount) < 8 { return 0 }
        return 0.5 + 0.02 * Double(min(10, runs - 8)) + 0.15 * min(1, (med - 230) / 100)
    }

    /// a cheer or a shout: 9 dB above this child's usual voice, held about 0.5 s without a break
    private func shout() -> Double {
        let n = min(count, 28)
        if n < 28 { return 0 }
        let vo = last(voiced, n), f = last(f0, n), r = last(rel, n)
        let need = max(22, voiceRef + 9)
        var run = 0, best = 0
        var mx = 0.0
        for i in 0..<n {
            if r[i] >= need && vo[i] == 1 && f[i] >= 250 { run += 1; best = max(best, run) } else { run = 0 }
            mx = max(mx, r[i])
        }
        return best >= 22 ? 0.72 + min(0.2, (mx - need) * 0.02) : 0
    }
}

/// Turns a stream of detections into moments: 40 % before the trigger, 60 % after,
/// stretched while the voice goes on (up to 1.5x), then 12 s of rest.
final class Grouper {
    struct Capture {
        var start: Int
        var end: Int
        var type: MomentTag
        var score: Double
        var evidence: [MomentTag: Double]
    }

    private let pre: Int, post: Int, maxLength: Int, cool: Int
    private(set) var current: Capture?
    private var coolUntil = Int.min
    private var done: [Capture] = []

    init(lengthSeconds: Int) {
        let sr = Double(Detector.sampleRate)
        pre = Int((Double(lengthSeconds) * 0.4 * sr).rounded())
        post = Int((Double(lengthSeconds) * 0.6 * sr).rounded())
        maxLength = Int((Double(lengthSeconds) * 1.5 * sr).rounded())
        cool = 12 * Detector.sampleRate
    }

    func event(_ ev: Detection, minStart: Int) {
        if let c = current, ev.at > c.end { finish() }
        if var c = current {
            // label the moment by what was heard most, not by one loud frame
            c.evidence[ev.type, default: 0] += ev.score
            if c.evidence[ev.type]! > c.evidence[c.type, default: 0] { c.type = ev.type }
            if ev.score > c.score { c.score = ev.score }
            c.end = min(max(c.end, ev.at + post / 2), c.start + maxLength)
            current = c
            return
        }
        if ev.at < coolUntil { return }
        current = Capture(start: max(minStart, ev.at - pre), end: ev.at + post, type: ev.type, score: ev.score, evidence: [ev.type: ev.score])
    }

    func finish() {
        if let c = current {
            done.append(c)
            coolUntil = c.end + cool
            current = nil
        }
    }

    /// Call after each block with the absolute sample position; returns moments that are complete.
    func advance(to position: Int) -> [Capture] {
        if let c = current, position >= c.end { finish() }
        let d = done
        done = []
        return d
    }

    /// Stop early (listening ended): close the open moment at `position`.
    func flush(at position: Int) -> [Capture] {
        if var c = current { c.end = min(c.end, position); current = c; finish() }
        return advance(to: position)
    }
}

/// Simple 3-tap smoothing + linear resampler (used by the command-line check; the app uses AVAudioConverter).
final class LinearResampler {
    private let ratio: Double
    private var t = 0.0, prev: Float = 0, p1: Float = 0, p2: Float = 0

    init(inputRate: Double) { ratio = inputRate / Double(Detector.sampleRate) }

    func process(_ x: [Float]) -> [Float] {
        if ratio == 1 { return x }
        let n = x.count
        if n == 0 { return [] }
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n { let v = x[i]; y[i] = 0.25 * p2 + 0.5 * p1 + 0.25 * v; p2 = p1; p1 = v }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(n) / ratio) + 2)
        var tt = t
        while tt < Double(n - 1) {
            let i = Int(tt.rounded(.down)), fr = Float(tt - Double(i))
            let a = i < 0 ? prev : y[i]
            out.append(a + (y[i + 1] - a) * fr)
            tt += ratio
        }
        t = tt - Double(n)
        prev = y[n - 1]
        return out
    }
}

enum WAV {
    /// 16-bit PCM mono at 24 kHz, with 0.25 s fades so clips don't click.
    static func encode(_ input: [Float], fade: Bool = true) -> Data {
        var x = input
        let fadeN = fade ? min(Int(0.25 * Double(Detector.sampleRate)), x.count >> 2) : 0
        if fadeN > 0 {
            for i in 0..<fadeN {
                let g = Float(i) / Float(fadeN)
                x[i] *= g
                x[x.count - 1 - i] *= g
            }
        }
        let sr = UInt32(Detector.sampleRate)
        var d = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(x.count * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(x.count * 2))
        var pcm = [Int16](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let c = max(-1, min(1, x[i]))
            pcm[i] = c < 0 ? Int16(c * 32768) : Int16(c * 32767)
        }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Reads 16-bit PCM WAV (any rate, mixes channels to mono). Used by the command-line check.
    static func decode(_ data: Data) -> (samples: [Float], rate: Double)? {
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        guard b.count > 44, String(bytes: b[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        var o = 12, channels = 1, rate = 0, bits = 16
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
            let size = u32(o + 4)
            if id == "fmt " { channels = u16(o + 10); rate = u32(o + 12); bits = u16(o + 22) }
            if id == "data" {
                guard bits == 16 else { return nil }
                let frames = min(size, b.count - o - 8) / (2 * channels)
                var out = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    var s = 0.0
                    for c in 0..<channels { s += Double(Int16(bitPattern: UInt16(u16(o + 8 + (i * channels + c) * 2)))) / 32768 }
                    out[i] = Float(s / Double(channels))
                }
                return (out, Double(rate))
            }
            o += 8 + size + (size & 1)
        }
        return nil
    }

    /// 64 peak values (0...1, square-root scaled) for drawing the waveform.
    static func peaks(_ x: [Float], buckets: Int = 64) -> [Double] {
        guard !x.isEmpty else { return [Double](repeating: 0, count: buckets) }
        var out = [Double](repeating: 0, count: buckets)
        let step = Double(x.count) / Double(buckets)
        var mx = 1e-6
        for b in 0..<buckets {
            let s = Int(Double(b) * step), e = min(x.count, Int(Double(b + 1) * step))
            var p = 0.0
            if s < e { for i in s..<e { p = max(p, Double(abs(x[i]))) } }
            out[b] = p
            mx = max(mx, p)
        }
        return out.map { (sqrt($0 / mx) * 100).rounded() / 100 }
    }
}
