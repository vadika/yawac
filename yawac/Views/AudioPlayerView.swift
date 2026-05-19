import AVKit
import SwiftUI

struct AudioPlayerView: View {
    let path: String
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var current: TimeInterval = 0
    @State private var timer: Timer?

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
        .onDisappear {
            player?.stop()
            timer?.invalidate()
        }
    }

    private func loadPlayer() {
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.prepareToPlay()
            self.player = p
            self.duration = p.duration
        } catch {
            self.player = nil
        }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            p.play()
            isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                Task { @MainActor in
                    self.current = p.currentTime
                    if !p.isPlaying {
                        self.isPlaying = false
                        self.timer?.invalidate()
                    }
                }
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
