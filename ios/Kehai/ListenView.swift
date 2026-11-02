import SwiftUI
import UniformTypeIdentifiers

struct ListenView: View {
    @EnvironmentObject private var listener: Listener
    @EnvironmentObject private var store: MomentStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var importer: FileImporter
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                EarView()
                    .frame(width: 280, height: 280)
                    .padding(.top, 4)
                Text("ポケットに入れておくだけ。笑い声や歌、おしゃべりが聞こえたら、その前後\(settings.lengthSeconds)秒だけを残します。ほかの音は端末の中ですぐ消えます。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    Button {
                        if listener.isListening { listener.stop() } else { listener.start() }
                    } label: {
                        Text(listener.isListening ? "やめる" : "耳をすます")
                    }
                    .buttonStyle(PillButtonStyle(filled: !listener.isListening))
                    if listener.isListening {
                        Text("画面を消してポケットに入れても、聴きつづけます。")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                }

                if let e = listener.errorMessage {
                    Text(e)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                }

                today
                fileBox
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { importer.run(url: url, store: store, settings: settings) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("けはい").font(Theme.display(26)).foregroundStyle(Theme.ink)
            Text("音だけの思い出帳").font(.caption).tracking(1.5).foregroundStyle(Theme.muted)
            Spacer()
            Text("試作 0.1 · iOS")
                .font(.caption2)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
    }

    private var today: some View {
        let key = MomentStore.dayKey(Date())
        let count = store.moments(on: key).count
        let listened = (store.listenSeconds[key] ?? 0) + listener.unsavedListeningSeconds
        return HStack(spacing: 0) {
            stat("きょう拾った瞬間", "\(count)")
            Divider().frame(height: 36)
            stat("耳をすませた時間", Format.minutes(listened))
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).tracking(0.8).foregroundStyle(Theme.muted)
            Text(value).font(Theme.display(22)).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity)
    }

    private var fileBox: some View {
        Card {
            Text("録音ファイルから拾う").font(.headline).foregroundStyle(Theme.ink)
            Text("ピンマイクやボイスメモで録った音、動画の音から、心が動いた瞬間を探します。長い録音も、少しずつ読みながら探します。")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("ファイルを選ぶ") { picking = true }
                .buttonStyle(PillButtonStyle(filled: false))
                .disabled(importer.isRunning)
                .padding(.top, 4)
            if importer.isRunning {
                ProgressView(value: importer.progress).tint(Theme.accent)
            }
            if let msg = importer.message {
                Text(msg).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The only loud object on the screen: a ring that breathes with the room and turns warm while it is keeping a moment.
struct EarView: View {
    @EnvironmentObject private var listener: Listener
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anim = EarAnimation()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !listener.isListening || listener.isInterrupted)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * 1000
            ZStack {
                Canvas { ctx, size in draw(&ctx, size, t) }
                VStack(spacing: 2) {
                    Text(stateText).font(Theme.display(19)).foregroundStyle(Theme.ink)
                    Text(timeText(timeline.date))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        guard listener.isListening else { return "しずかです" }
        if listener.isInterrupted { return "中断しています" }
        if listener.isCapturing { return "拾っています" }
        return listener.level > 0.35 ? "聞こえます" : "耳をすませています"
    }

    private func timeText(_ now: Date) -> String {
        guard listener.isListening, let s = listener.startedAt else { return "止まっています" }
        return Format.duration(now.timeIntervalSince(s))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = w * 0.3
        let on = listener.isListening && !listener.isInterrupted
        let cap = on && listener.isCapturing
        anim.level += ((on ? listener.level : 0) - anim.level) * 0.2
        let lvl = anim.level

        if on && !reduceMotion {
            let gap = 1400 - lvl * 900
            if t - anim.lastRipple > gap {
                anim.ripples.append((t0: t, a: 0.18 + lvl * 0.5))
                anim.lastRipple = t
            }
            anim.ripples.removeAll { t - $0.t0 >= 3200 }
            for rp in anim.ripples {
                let p = (t - rp.t0) / 3200
                let rr = r + p * w * 0.19
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color((cap ? Theme.accent : Theme.ink).opacity(rp.a * (1 - p))), lineWidth: w * 0.004)
            }
        } else {
            anim.ripples.removeAll()
        }

        let rr = r + lvl * w * 0.05
        let circle = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        let fillAlpha = cap ? 0.16 : (on ? 0.05 + lvl * 0.08 : 0.03)
        ctx.fill(circle, with: .color((cap ? Theme.accent : Theme.ink).opacity(fillAlpha)))
        ctx.stroke(circle, with: .color(cap ? Theme.accent : (on ? Theme.ink : Theme.line)), lineWidth: w * (cap ? 0.008 : 0.004))
    }
}

/// Animation state that lives outside SwiftUI's diffing (changed while drawing, never observed).
final class EarAnimation {
    var ripples: [(t0: Double, a: Double)] = []
    var lastRipple = 0.0
    var level = 0.0
}
