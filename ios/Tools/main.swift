import Foundation

// Command-line check that the Swift detector picks the same moments as the web version.
//   swiftc -O ios/Kehai/Detection.swift ios/Tools/main.swift -o /tmp/kehai-check
//   /tmp/kehai-check test/test.wav
// Expected for test/test.wav (made by test/gen.py): laugh, sing, chat, shout, and nothing for the adult voice or the door.

let args = CommandLine.arguments
guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]), let wav = WAV.decode(data) else {
    print("usage: kehai-check file.wav (16-bit PCM)")
    exit(2)
}
let resampler = LinearResampler(inputRate: wav.rate)
let x = resampler.process(wav.samples)
let detector = Detector()
let grouper = Grouper(lengthSeconds: 20)
var caps: [Grouper.Capture] = []
var runs: [(start: Double, end: Double, type: MomentTag, max: Double)] = []
let block = 4096
var pos = 0
let sr = Double(Detector.sampleRate)
while pos < x.count {
    let end = min(x.count, pos + block)
    for ev in detector.feed(x[pos..<end]) {
        let t = Double(ev.at) / sr
        if let last = runs.last, last.type == ev.type, t - last.end < 1 {
            runs[runs.count - 1].end = t
            runs[runs.count - 1].max = max(last.max, ev.score)
        } else {
            runs.append((t, t, ev.type, ev.score))
        }
        grouper.event(ev, minStart: 0)
    }
    pos = end
    caps += grouper.advance(to: pos)
}
caps += grouper.flush(at: x.count)
print("detections:")
for r in runs { print(String(format: "  %6.1f-%6.1f s  ", r.start, r.end) + r.type.label + String(format: "  max %.2f", r.max)) }
print("moments:")
for c in caps { print(String(format: "  %6.1f s  ", Double(c.start) / sr) + c.type.label + String(format: "  score %.2f  %.1f s", c.score, Double(c.end - c.start) / sr)) }
let got = caps.map { $0.type.rawValue }
let expected = ["laugh", "sing", "chat", "shout"]
print(got == expected ? "OK: matches the web version" : "DIFFERENT: expected \(expected), got \(got)")
exit(got == expected ? 0 : 1)
