import AVKit
import SwiftUI

struct LogView: View {
    @EnvironmentObject private var store: MomentStore
    @EnvironmentObject private var player: Player

    var body: some View {
        NavigationStack {
            List {
                if store.moments.isEmpty {
                    Section {
                        ForEach(Example.day) { ex in ExampleRow(example: ex) }
                    } header: {
                        dayHeader(title: "見本の一日", detail: "実際に拾われると、日ごとにここへ並びます", list: nil)
                    }
                    Section {
                        Text("まだ瞬間はありません。「きく」で耳をすますか、録音ファイルから拾ってみてください。")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.surface)
                    }
                } else {
                    ForEach(store.dayKeys, id: \.self) { key in
                        let list = store.moments(on: key)
                        Section {
                            ForEach(list) { m in
                                MomentRow(moment: m)
                                    .swipeActions(edge: .trailing) {
                                        Button("消す", role: .destructive) { delete(m) }
                                    }
                                    .contextMenu {
                                        ShareLink(item: store.url(for: m)) { Label("共有", systemImage: "square.and.arrow.up") }
                                        Button("消す", systemImage: "trash", role: .destructive) { delete(m) }
                                    }
                            }
                        } header: {
                            dayHeader(title: Format.day(key), detail: summary(key, list), list: list)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("きろく")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // where to play: this iPhone's speaker, a Bluetooth speaker, AirPlay
                    RoutePicker().frame(width: 36, height: 36).accessibilityLabel("再生するスピーカーを選ぶ")
                }
            }
        }
    }

    private func summary(_ key: String, _ list: [Moment]) -> String {
        let total = list.reduce(0) { $0 + $1.duration }
        let listened = store.listenSeconds[key].map { Format.minutes($0) + "耳をすませて、" } ?? ""
        return listened + "\(list.count)つの瞬間 · 合計" + Format.duration(total)
    }

    private func dayHeader(title: String, detail: String, list: [Moment]?) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.display(18)).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let list, !list.isEmpty {
                Button("通して聴く") { player.playDay(list) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }

    private func delete(_ m: Moment) {
        if player.playingID == m.id { player.stop() }
        store.delete(m)
    }
}

struct MomentRow: View {
    let moment: Moment
    @EnvironmentObject private var store: MomentStore
    @EnvironmentObject private var player: Player
    @State private var note: String
    @FocusState private var editing: Bool
    @State private var showAll = false

    init(moment: Moment) {
        self.moment = moment
        _note = State(initialValue: moment.note)
    }

    private var playing: Bool { player.playingID == moment.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { player.toggle(moment) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(playing ? Theme.bg : Theme.ink)
                    .background(Circle().fill(playing ? Theme.tag(moment.tag) : Theme.bg))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? "止める" : "再生")

            VStack(alignment: .leading, spacing: 6) {
                MetaLine(date: moment.date, tag: moment.tag, duration: moment.duration, fromFile: moment.sourceFile != nil, example: false) { t in
                    store.setTag(moment.id, t, byUser: true)
                }
                if playing {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                        Waveform(peaks: moment.peaks, color: Theme.tag(moment.tag), progress: player.progress(of: moment.id))
                    }
                } else {
                    Waveform(peaks: moment.peaks, color: Theme.tag(moment.tag), progress: 0)
                }
                if let t = moment.transcript, !t.isEmpty {
                    Text("「" + t + "」")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .lineLimit(showAll ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { showAll.toggle() }
                        .accessibilityLabel("話していたこと: " + t)
                }
                TextField("ひとことメモ", text: $note)
                    .font(.subheadline)
                    .focused($editing)
                    .submitLabel(.done)
                    .onSubmit { store.setNote(moment.id, note) }
                    .onChange(of: editing) { _, now in if !now { store.setNote(moment.id, note) } }
            }

            Button { store.toggleFavorite(moment.id) } label: {
                Image(systemName: moment.favorite ? "heart.fill" : "heart")
                    .font(.system(size: 17))
                    .frame(width: 36, height: 40)
                    .foregroundStyle(moment.favorite ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(moment.favorite ? "お気に入りから外す" : "お気に入り")
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.surface)
    }
}

struct MetaLine: View {
    let date: Date
    let tag: MomentTag
    let duration: Double
    let fromFile: Bool
    let example: Bool
    /// when set, tapping the label lets the person correct it
    var onTag: ((MomentTag) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.time(date)).monospacedDigit().foregroundStyle(Theme.ink)
            if let onTag {
                Menu {
                    ForEach(MomentTag.allCases, id: \.self) { t in
                        Button(t.label) { onTag(t) }
                    }
                } label: { chip }
                .accessibilityLabel(tag.label + "、タップで直せます")
            } else {
                chip
            }
            Text(Format.duration(duration))
            if fromFile { Text("ファイルから") }
            if example { Text("見本") }
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
    }

    private var chip: some View {
        Text(tag.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.tag(tag))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.tag(tag).opacity(0.14)))
    }
}

/// The system's output picker (speaker / Bluetooth / AirPlay).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.activeTintColor = UIColor(Theme.accent)
        v.tintColor = UIColor(Theme.muted)
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// 64 bars, square-root scaled when saved; the part already heard is drawn solid.
struct Waveform: View {
    let peaks: [Double]
    let color: Color
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let n = CGFloat(peaks.count)
            let bw = size.width / n
            for (i, p) in peaks.enumerated() {
                let h = max(1.2, p * 22) / 26 * size.height
                let rect = CGRect(x: CGFloat(i) * bw + bw * 0.2, y: (size.height - h) / 2, width: bw * 0.6, height: h)
                let heard = (CGFloat(i) + 0.5) / n <= progress
                ctx.fill(Path(roundedRect: rect, cornerRadius: bw * 0.3), with: .color(color.opacity(heard ? 1 : 0.28)))
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}

// MARK: the sample day shown before anything has been picked

struct Example: Identifiable {
    let id: Int
    let minutes: Int
    let duration: Double
    let tag: MomentTag
    let note: String
    let peaks: [Double]

    static func peaks(seed: Int, _ shape: (Double, Double) -> Double) -> [Double] {
        var s = seed
        return (0..<64).map { i in
            s = (s * 9301 + 49297) % 233280
            let r = Double(s) / 233280, t = Double(i) / 63
            return max(0.05, min(1, shape(t, r)))
        }
    }

    static let day: [Example] = [
        Example(id: 1, minutes: 7 * 60 + 42, duration: 20, tag: .sing, note: "お風呂のうた", peaks: peaks(seed: 3) { t, r in
            let middle: Double = (t > 0.3 && t < 0.9) ? 1 : 0.3
            let wave: Double = abs(sin(t * 19))
            return 0.25 + 0.6 * wave * middle + r * 0.1
        }),
        Example(id: 2, minutes: 17 * 60 + 5, duration: 22, tag: .laugh, note: "帰りの車で止まらない笑い", peaks: peaks(seed: 7) { t, r in
            let burst = t > 0.38 && t < 0.7
            return burst ? 0.5 + r * 0.5 : 0.12 + r * 0.15
        }),
        Example(id: 3, minutes: 19 * 60 + 30, duration: 20, tag: .chat, note: "「あのね、きょうね」", peaks: peaks(seed: 11) { t, r in
            let syllable: Double = r > 0.45 ? 0.3 + r * 0.55 : 0.1 + r * 0.2
            let after: Double = t > 0.35 ? 1 : 0.4
            return syllable * after
        }),
    ]
}

struct ExampleRow: View {
    let example: Example

    var body: some View {
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(example.minutes) * 60)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "play.fill")
                .font(.system(size: 15))
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.muted)
                .background(Circle().fill(Theme.bg))
            VStack(alignment: .leading, spacing: 6) {
                MetaLine(date: date, tag: example.tag, duration: example.duration, fromFile: false, example: true)
                Waveform(peaks: example.peaks, color: Theme.tag(example.tag), progress: 0)
                Text(example.note).font(.subheadline).foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(0.75)
        .listRowBackground(Theme.surface)
        .accessibilityLabel("見本: " + example.tag.label + "、" + example.note)
    }
}
