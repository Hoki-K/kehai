import SwiftUI

@main
struct KehaiApp: App {
    @StateObject private var store: MomentStore
    @StateObject private var settings: AppSettings
    @StateObject private var listener: Listener
    @StateObject private var player: Player
    @StateObject private var importer = FileImporter()

    init() {
        let store = MomentStore()
        let settings = AppSettings()
        let listener = Listener(store: store, settings: settings)
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _listener = StateObject(wrappedValue: listener)
        _player = StateObject(wrappedValue: Player(store: store) { [weak listener] in listener?.isListening ?? false })
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(listener)
                .environmentObject(player)
                .environmentObject(importer)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: MomentStore
    @EnvironmentObject private var listener: Listener
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var importer: FileImporter
    @State private var tab = 0
    @State private var unseen = 0
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $tab) {
            ListenView()
                .tabItem { Label("きく", systemImage: "ear") }
                .tag(0)
            LogView()
                .tabItem { Label("きろく", systemImage: "waveform") }
                .badge(unseen)
                .tag(1)
            SettingsView()
                .tabItem { Label("せってい", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.ink))
                    .padding(.bottom, 64)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: listener.lastSaved?.id) { _, id in
            guard id != nil, let m = listener.lastSaved else { return }
            if tab != 1 { unseen += 1 }
            show(m.tag.label + "を拾いました")
        }
        .onChange(of: importer.isRunning) { _, running in
            guard !running, importer.lastCount > 0 else { return }
            if tab != 1 { unseen += importer.lastCount }
            show("\(importer.lastCount)つの瞬間を拾いました")
        }
        .onChange(of: tab) { _, t in if t == 1 { unseen = 0 } }
        .onChange(of: player.playingID) { _, id in listener.setMuted(id != nil) }
    }

    private func show(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
        }
    }
}
