import AVFoundation
import Combine
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: MomentStore
    @EnvironmentObject private var listener: Listener
    @EnvironmentObject private var player: Player
    @State private var inputs: [AVAudioSessionPortDescription] = []
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("拾う感度", selection: $settings.sensitivity) {
                        ForEach(Sensitivity.allCases, id: \.self) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("拾う感度") } footer: {
                    Text("「たくさん」は取りこぼしが減るかわりに、ただの物音も拾いやすくなります。")
                }

                Section {
                    Picker("ひとつの瞬間の長さ", selection: $settings.lengthSeconds) {
                        Text("15秒（前6秒・後9秒）").tag(15)
                        Text("20秒（前8秒・後12秒）").tag(20)
                        Text("30秒（前12秒・後18秒）").tag(30)
                    }
                    Picker("1日に残す数", selection: $settings.dailyCap) {
                        Text("10個まで").tag(10)
                        Text("20個まで").tag(20)
                        Text("40個まで").tag(40)
                    }
                } header: { Text("残し方") } footer: {
                    Text("声が続いているあいだは、最大1.5倍まで延びます。上限をこえると、お気に入り以外でいちばん印象の弱い瞬間と入れ替えます。長さは、次に耳をすますときから変わります。")
                }

                Section {
                    Picker("マイク", selection: $settings.inputUID) {
                        Text("端末の標準マイク").tag("")
                        ForEach(inputs, id: \.uid) { p in Text(p.portName).tag(p.uid) }
                        if !settings.inputUID.isEmpty && !inputs.contains(where: { $0.uid == settings.inputUID }) {
                            // remembered for when the receiver is plugged back in
                            Text("いまはつながっていないマイク").tag(settings.inputUID)
                        }
                    }
                } header: { Text("マイク") } footer: {
                    Text("有線やUSBでつなぐワイヤレスピンマイクの受信機は、つなぐとここに出てきます。Bluetoothのイヤホンのマイクは、音が細くなるため使いません。")
                }

                Section {
                    Toggle("話した内容を文字にする", isOn: $settings.transcribe)
                    Text("雑音除去はかけずに、その場の空気感ごと残します。小さく録れた瞬間は、保存するときに音量だけそろえます。")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } header: { Text("音の扱い") } footer: {
                    Text("文字にする処理も、種類（笑い声・うた など）の見分けも、この端末の中だけで行います。端末が日本語の端末内認識に対応していないときは、文字にしません。")
                }

                Section {
                    Text(usage).font(.footnote).foregroundStyle(Theme.muted)
                    if !store.moments.isEmpty {
                        ShareLink(items: store.moments.sorted { $0.date < $1.date }.map { store.url(for: $0) }) {
                            Label("すべて書き出す", systemImage: "square.and.arrow.up")
                        }
                        Button("すべて消す", role: .destructive) { confirmWipe = true }
                    }
                } header: { Text("データ") } footer: {
                    Text("録った音は「ファイル」アプリの「このiPhone内」→「けはい」→「Moments」にも入っています。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("・音の解析はすべてこの端末の中で行い、どこにも送りません。")
                        Text("・残すのは、拾った瞬間の前後だけです。それ以外の音は保存しません。")
                        Text("・拾う判定は試作段階の簡単な仕組みです。外れることがあります。")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                } header: { Text("このアプリについて") } footer: {
                    Text("けはい 試作 " + version)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("せってい")
            .onAppear(perform: refreshInputs)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
                refreshInputs()
            }
            .onChange(of: settings.sensitivity) { _, s in listener.applySensitivity(s) }
            .onChange(of: settings.inputUID) { _, _ in listener.inputChanged() }
            .confirmationDialog("保存した瞬間をすべて消しますか？", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("すべて消す", role: .destructive) {
                    player.stop()
                    store.deleteAll()
                }
            } message: {
                Text("消した音は元に戻せません。")
            }
        }
    }

    private var usage: String {
        store.moments.isEmpty
            ? "保存している瞬間はありません。"
            : "\(store.moments.count)つの瞬間を、この端末に保存しています（約" + Format.megabytes(store.totalBytes) + "）。"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The list of inputs is only filled in while the session allows recording.
    private func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        if !listener.isListening && player.playingID == nil {
            try? session.setCategory(.playAndRecord, mode: .default, options: Listener.sessionOptions)
        }
        inputs = (session.availableInputs ?? []).filter { $0.portType != .builtInMic && $0.portType != .bluetoothHFP }
    }
}
