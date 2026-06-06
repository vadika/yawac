import AVFoundation
import AVKit
import SwiftUI

struct AudioPlayerView: View {
    let path: String
    /// Raw amplitude bytes from the proto for inbound voice notes. nil
    /// for music clips, outbound sends, or older messages — those keep
    /// the plain ProgressView.
    var waveform: Data? = nil
    /// Voice-note flag. Together with a non-empty waveform this flips
    /// the row to the WhatsApp-style amplitude bars.
    var isPTT: Bool = false

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var current: TimeInterval = 0
    @State private var timer: Timer?
    @State private var observer: NSObjectProtocol?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                if isPTT, let bytes = waveform, !bytes.isEmpty {
                    WaveformBarsView(
                        bytes: bytes,
                        progress: progressFraction,
                        tintPlayed: Theme.accent,
                        tintUnplayed: Theme.textMuted)
                        .frame(width: 160)
                } else {
                    ProgressView(value: current, total: max(duration, 1))
                        .progressViewStyle(.linear)
                        .frame(width: 160)
                }
                Text(formatTime(duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .onAppear { loadPlayer() }
        .onDisappear { teardown() }
    }

    /// Playback fraction in `[0, 1]`. Falls back to 0 while the asset
    /// duration is still loading.
    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, max(0.0, current / duration))
    }

    private func loadPlayer() {
        // AVPlayer + AVAsset supports more codecs than AVAudioPlayer —
        // notably Ogg-Opus (which WhatsApp voice notes use) on macOS
        // 12+ via the system audio codec. AVAudioPlayer rejects Opus.
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // AirPods head-tracked spatial audio: by default macOS routes
        // every AVPlayer through `binh` (binaural head-tracked) when
        // the route is head-tracked headphones, which spawns a
        // HeadTrackerSession that polls the IMU at hundreds of hertz
        // for the lifetime of the player. Voice notes are mono and
        // don't benefit from spatialization — opting out drops the
        // head-tracker polling that was driving ~500 wakes/sec.
        item.allowedAudioSpatializationFormats = []
        let p = AVPlayer(playerItem: item)
        self.player = p
        Task { @MainActor in
            do {
                let dur = try await asset.load(.duration)
                self.duration = CMTimeGetSeconds(dur)
            } catch {
                self.duration = 0
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { _ in
            isPlaying = false
            current = 0
            timer?.invalidate()
            p.seek(to: .zero)
        }
    }

    private func teardown() {
        player?.pause()
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            p.play()
            isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                Task { @MainActor in
                    self.current = CMTimeGetSeconds(p.currentTime())
                    if p.rate == 0, self.isPlaying { /* paused externally */ }
                }
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
