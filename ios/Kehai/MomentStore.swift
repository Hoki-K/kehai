import Foundation

struct Moment: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let duration: Double
    let tag: MomentTag
    let score: Double
    let peaks: [Double]
    var favorite: Bool
    var note: String
    let fileName: String
    /// name of the recording it came from, when it was picked from a file rather than heard live
    var sourceFile: String? = nil
}

/// Saved moments: WAV files in Documents/Moments (visible in the Files app) plus a small JSON index.
final class MomentStore: ObservableObject {
    @Published private(set) var moments: [Moment] = []
    @Published private(set) var listenSeconds: [String: Double] = [:]

    let folder: URL
    private let indexURL: URL

    private struct Index: Codable {
        var moments: [Moment]
        var listenSeconds: [String: Double]
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Moments", isDirectory: true)
        indexURL = docs.appendingPathComponent("moments.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            moments = index.moments.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
            listenSeconds = index.listenSeconds
        }
    }

    func url(for m: Moment) -> URL { folder.appendingPathComponent(m.fileName) }

    private func persist() {
        let index = Index(moments: moments, listenSeconds: listenSeconds)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func moments(on key: String) -> [Moment] {
        moments.filter { MomentStore.dayKey($0.date) == key }.sorted { $0.date < $1.date }
    }

    var dayKeys: [String] { Array(Set(moments.map { MomentStore.dayKey($0.date) })).sorted(by: >) }

    /// Saves a moment. When the day is full, a live moment replaces the weakest one that isn't a favourite.
    /// Moments from a file skip the daily cap (the importer already chose the best few).
    @discardableResult
    func add(samples: [Float], date: Date, tag: MomentTag, score: Double, dailyCap: Int, sourceFile: String? = nil) -> Moment? {
        let key = MomentStore.dayKey(date)
        let today = moments.filter { MomentStore.dayKey($0.date) == key }
        if sourceFile == nil && today.count >= dailyCap {
            guard let weakest = today.filter({ !$0.favorite }).min(by: { $0.score < $1.score }), weakest.score < score else { return nil }
            delete(weakest)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        var name = "\(f.string(from: date))_\(tag.rawValue).wav"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(f.string(from: date))_\(tag.rawValue)_\(n).wav"
            n += 1
        }
        do { try WAV.encode(samples).write(to: folder.appendingPathComponent(name), options: .atomic) } catch { return nil }
        let m = Moment(id: UUID(), date: date, duration: Double(samples.count) / Double(Detector.sampleRate), tag: tag,
                       score: (score * 100).rounded() / 100, peaks: WAV.peaks(samples), favorite: false, note: "", fileName: name,
                       sourceFile: sourceFile)
        moments.append(m)
        persist()
        return m
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        moments[i].favorite.toggle()
        persist()
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let i = moments.firstIndex(where: { $0.id == id }), moments[i].note != note else { return }
        moments[i].note = String(note.prefix(60))
        persist()
    }

    func delete(_ m: Moment) {
        try? FileManager.default.removeItem(at: url(for: m))
        moments.removeAll { $0.id == m.id }
        persist()
    }

    func deleteAll() {
        for m in moments { try? FileManager.default.removeItem(at: url(for: m)) }
        moments = []
        persist()
    }

    func addListening(seconds: Double, at date: Date = Date()) {
        guard seconds > 0 else { return }
        listenSeconds[MomentStore.dayKey(date), default: 0] += seconds
        persist()
    }

    var totalBytes: Int64 {
        moments.reduce(0) { sum, m in
            let size = (try? FileManager.default.attributesOfItem(atPath: url(for: m).path)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }
}

/// User choices, kept in UserDefaults.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var sensitivity: Sensitivity { didSet { d.set(sensitivity.rawValue, forKey: "sensitivity") } }
    @Published var lengthSeconds: Int { didSet { d.set(lengthSeconds, forKey: "lengthSeconds") } }
    @Published var dailyCap: Int { didSet { d.set(dailyCap, forKey: "dailyCap") } }
    @Published var inputUID: String { didSet { d.set(inputUID, forKey: "inputUID") } }

    init() {
        sensitivity = Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .mid
        let len = d.integer(forKey: "lengthSeconds")
        lengthSeconds = [15, 20, 30].contains(len) ? len : 20
        let cap = d.integer(forKey: "dailyCap")
        dailyCap = [10, 20, 40].contains(cap) ? cap : 20
        inputUID = d.string(forKey: "inputUID") ?? ""
    }
}
