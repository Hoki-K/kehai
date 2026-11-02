import AVFoundation
import Foundation

/// Plays saved moments, one at a time or a whole day in a row ("通して聴く").
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?

    private let store: MomentStore
    private let isListening: () -> Bool
    private var player: AVAudioPlayer?
    private var queue: [Moment] = []

    init(store: MomentStore, isListening: @escaping () -> Bool) {
        self.store = store
        self.isListening = isListening
    }

    /// 0...1 for the moment that is playing, read by the waveform while it redraws.
    func progress(of id: UUID) -> Double {
        guard id == playingID, let p = player, p.duration > 0 else { return 0 }
        return min(1, p.currentTime / p.duration)
    }

    func toggle(_ m: Moment) {
        if playingID == m.id { stop() } else {
            queue = []
            play(m)
        }
    }

    func playDay(_ list: [Moment]) {
        guard let first = list.first else { return }
        queue = Array(list.dropFirst())
        play(first)
    }

    func stop() {
        player?.stop()
        player = nil
        queue = []
        playingID = nil
        if !isListening() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func play(_ m: Moment) {
        player?.stop()
        // while listening, the session is already play-and-record (through the speaker); leave it alone
        if !isListening() {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default)
            try? s.setActive(true)
        }
        guard let p = try? AVAudioPlayer(contentsOf: store.url(for: m)) else {
            next()
            return
        }
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        playingID = m.id
    }

    private func next() {
        if queue.isEmpty { stop() } else { play(queue.removeFirst()) }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, p === self.player else { return }
            self.next()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, p === self.player else { return }
            self.next()
        }
    }
}
