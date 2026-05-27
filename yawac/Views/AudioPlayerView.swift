import AVFoundation
import AVKit
import SwiftUI

struct AudioPlayerView: View {
    let path: String
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
                ProgressView(value: current, total: max(duration, 1))
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                Text(formatTime(duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .onAppear { loadPlayer() }
        .onDisappear { teardown() }
    }

    private func loadPlayer() {
        // AVPlayer + AVAsset supports more codecs than AVAudioPlayer —
        // notably Ogg-Opus (which WhatsApp voice notes use) on macOS
        // 12+ via the system audio codec. AVAudioPlayer rejects Opus.
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
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
