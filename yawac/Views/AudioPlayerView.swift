import AVFoundation
import AVKit
import os
import SwiftUI

/// Wake-rate hunt instrumentation. Counts live AudioPlayerView audio
/// instances (either AVPlayer or OpusVoicePlayer). v0.9.28 lazy-mount
/// dropped idle-row wakes; the counter still tracks playback duration
/// so we can correlate any future regressions to the wake-rate probe.
private nonisolated(unsafe) var audioPlayerLiveCount = 0
private let audioPlayerCountLock = NSLock()
private let audioPlayerPerfLog = Logger(subsystem: "dev.vadikas.yawac.yawac",
                                        category: "perf")

private func audioPlayerDidCreate(kind: String) {
    audioPlayerCountLock.lock()
    audioPlayerLiveCount += 1
    let n = audioPlayerLiveCount
    audioPlayerCountLock.unlock()
    audioPlayerPerfLog.log("AudioPlayerView +1 live=\(n, privacy: .public) kind=\(kind, privacy: .public)")
}

private func audioPlayerDidTeardown(kind: String) {
    audioPlayerCountLock.lock()
    audioPlayerLiveCount -= 1
    let n = audioPlayerLiveCount
    audioPlayerCountLock.unlock()
    audioPlayerPerfLog.log("AudioPlayerView -1 live=\(n, privacy: .public) kind=\(kind, privacy: .public)")
}

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
    @State private var opusPlayer: OpusVoicePlayer?
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var current: TimeInterval = 0
    @State private var timer: Timer?
    @State private var observer: NSObjectProtocol?
    /// True once the magic-byte probe confirms the file starts with
    /// "OggS". Set by `prefetchDuration` (or lazily inside `togglePlay`
    /// if the user beats the async prefetch). Extension-based gating —
    /// used in the first v0.9.29 cut — missed files because WhatsApp's
    /// media-cache path isn't always `.ogg`, so the AVPlayer wake leak
    /// reappeared in real chats. Sniffing the container magic instead
    /// makes the routing robust to whatever filename the cache emits.
    @State private var bypassReady = false

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
        // No eager mount. The audio engine — AVPlayer or AVAudioEngine —
        // is created on the first togglePlay tap. prefetchDuration uses
        // a cheap header parse (Ogg granule for bypass, AVURLAsset for
        // AVPlayer path) so the duration label renders without waking
        // the audio stack.
        .onAppear { Task { @MainActor in await prefetchDuration() } }
        .onDisappear { teardown() }
    }

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, max(0.0, current / duration))
    }

    private func prefetchDuration() async {
        let url = URL(fileURLWithPath: path)
        if OggOpusDemuxer.isOggFile(url: url) {
            bypassReady = true
            audioPlayerPerfLog.log("AudioPlayerView bypass=opus path=\(path, privacy: .public)")
            if duration == 0,
               let d = OggOpusDemuxer.peekDurationSeconds(url: url) {
                self.duration = d
            }
            return
        }
        guard duration == 0 else { return }
        let asset = AVURLAsset(url: url)
        do {
            let dur = try await asset.load(.duration)
            self.duration = CMTimeGetSeconds(dur)
        } catch {
            self.duration = 0
        }
    }

    private func loadAVPlayer() {
        // AVPlayer + AVAsset supports more codecs than AVAudioPlayer —
        // notably the m4a/aac that non-PTT clips can use. Voice notes
        // (Ogg-Opus) take the bypass path above.
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = []
        let p = AVPlayer(playerItem: item)
        self.player = p
        audioPlayerDidCreate(kind: "av")
        if duration == 0 {
            Task { @MainActor in
                do {
                    let dur = try await asset.load(.duration)
                    self.duration = CMTimeGetSeconds(dur)
                } catch {
                    self.duration = 0
                }
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

    private func loadOpusPlayer() {
        let url = URL(fileURLWithPath: path)
        do {
            let p = try OpusVoicePlayer(url: url)
            self.opusPlayer = p
            if self.duration == 0 { self.duration = p.duration }
            audioPlayerDidCreate(kind: "opus")
        } catch {
            audioPlayerPerfLog.error("OpusVoicePlayer init failed for \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if let p = player {
            p.pause()
            p.replaceCurrentItem(with: nil)
            audioPlayerDidTeardown(kind: "av")
        }
        if let op = opusPlayer {
            op.teardown()
            audioPlayerDidTeardown(kind: "opus")
        }
        player = nil
        opusPlayer = nil
        isPlaying = false
        current = 0
    }

    private func togglePlay() {
        // Race: if the user taps before prefetchDuration's async probe
        // landed, sniff the magic bytes synchronously here. The read is
        // ~10 µs so the tap stays interactive. After this, bypassReady
        // is authoritative for the lifetime of the view.
        if !bypassReady && player == nil && opusPlayer == nil {
            if OggOpusDemuxer.isOggFile(url: URL(fileURLWithPath: path)) {
                bypassReady = true
                audioPlayerPerfLog.log("AudioPlayerView bypass=opus (late) path=\(path, privacy: .public)")
            }
        }
        if bypassReady {
            togglePlayOpus()
        } else {
            togglePlayAV()
        }
    }

    private func togglePlayAV() {
        if player == nil { loadAVPlayer() }
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
                }
            }
        }
    }

    private func togglePlayOpus() {
        if opusPlayer == nil { loadOpusPlayer() }
        guard let op = opusPlayer else { return }
        if isPlaying {
            op.pause()
            isPlaying = false
            current = op.currentTime
            timer?.invalidate()
        } else {
            op.play()
            isPlaying = op.isPlaying
            guard isPlaying else { return }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                Task { @MainActor in
                    op.tick()
                    self.current = op.currentTime
                    if !op.isPlaying, self.isPlaying {
                        self.isPlaying = false
                        self.current = 0
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
