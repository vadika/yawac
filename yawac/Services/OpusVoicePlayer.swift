import AVFoundation
import COpus
import Foundation
import OSLog

/// Drop-in voice-note player that bypasses AVPlayer entirely. Decodes
/// the Ogg-Opus file in one shot to a single Float32 PCM buffer, then
/// plays it through an AVAudioEngine graph. Wakes attributable to
/// playback drop dramatically because there's no FigPlayer / Boss /
/// FigAirPlay_Route / HeadTrackerSession plumbing involved.
///
/// Used only for `isPTT` voice notes whose URL ends in .ogg/.opus. The
/// non-PTT path (music clips, outbound sends, legacy m4a) keeps AVPlayer.
@MainActor
final class OpusVoicePlayer {
    enum Failure: Error {
        case notOpus
        case decoderInit(Int32)
        case bufferAlloc
    }

    private let log = Logger(subsystem: "dev.vadikas.yawac.yawac",
                             category: "voice-player")

    /// Total decoded duration in seconds, excluding the pre-skip head.
    let duration: TimeInterval

    /// Current playback offset in seconds. Polled by the host view's
    /// timer; AVAudioPlayerNode exposes its render position through
    /// `lastRenderTime` / `playerTime(forNodeTime:)`.
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    private let buffer: AVAudioPCMBuffer
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    /// Render frame at which the current playback segment was scheduled.
    /// Subtract from `node.lastRenderTime.sampleTime` to derive elapsed
    /// time across pause/resume cycles.
    private var nodeStartFrame: AVAudioFramePosition = 0
    /// Where in the buffer we last resumed from, in seconds. Combined
    /// with `nodeStartFrame` to compute `currentTime`.
    private var resumeAnchor: TimeInterval = 0

    private nonisolated static let sampleRate: Double = 48_000   // Opus always 48 kHz internal

    /// Full-file decode — CPU-bound, seconds for long notes. nonisolated so
    /// callers run it off MainActor; the returned buffer is moved, not shared.
    nonisolated static func decodeBuffer(url: URL) throws -> AVAudioPCMBuffer {
        let demuxer = try OggOpusDemuxer(url: url)
        let allPackets = demuxer.packets
        // Need at least OpusHead + OpusTags + 1 audio packet to be playable.
        guard allPackets.count >= 3 else { throw Failure.notOpus }

        var err: Int32 = 0
        guard let dec = opus_decoder_create(Int32(Self.sampleRate),
                                            1, &err),
              err == OPUS_OK else {
            throw Failure.decoderInit(err)
        }
        defer { opus_decoder_destroy(dec) }

        // 120 ms is the longest single Opus frame, = 5760 samples at 48 kHz.
        let perPacket: Int32 = 5760
        var pcm = [Float]()
        // Most voice-note packets are 60 ms (2880 samples). Reserve that.
        pcm.reserveCapacity(allPackets.count * 2880)
        var scratch = [Float](repeating: 0, count: Int(perPacket))

        let audioPackets = allPackets.dropFirst(2)   // skip OpusHead, OpusTags
        for packet in audioPackets {
            let frames = packet.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return scratch.withUnsafeMutableBufferPointer { dst in
                    opus_decode_float(dec, base, Int32(packet.count),
                                      dst.baseAddress!, perPacket, 0)
                }
            }
            if frames > 0 {
                pcm.append(contentsOf: scratch.prefix(Int(frames)))
            }
        }

        // Pre-skip head per RFC 7845. Voice notes use ~80 ms (3840
        // samples); discarding gives a clean attack.
        let skip = min(demuxer.preSkip, pcm.count)
        if skip > 0 { pcm.removeFirst(skip) }

        let frameCount = AVAudioFrameCount(pcm.count)
        guard frameCount > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Self.sampleRate,
                                       channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                          frameCapacity: frameCount) else {
            throw Failure.bufferAlloc
        }
        buf.frameLength = frameCount
        pcm.withUnsafeBufferPointer { src in
            buf.floatChannelData!.pointee.update(from: src.baseAddress!,
                                                 count: pcm.count)
        }
        return buf
    }

    convenience init(url: URL) throws {
        self.init(buffer: try Self.decodeBuffer(url: url))
    }

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
        self.duration = Double(buffer.frameLength) / Self.sampleRate
    }

    /// Builds the engine lazily so an idle voice-note row in the list
    /// doesn't allocate audio resources. Cleared by `teardown()`.
    private func ensureEngine() {
        if engine != nil { return }
        let e = AVAudioEngine()
        let n = AVAudioPlayerNode()
        e.attach(n)
        e.connect(n, to: e.mainMixerNode, format: buffer.format)
        e.prepare()
        self.engine = e
        self.node = n
    }

    func play() {
        ensureEngine()
        guard let engine, let node else { return }
        if !engine.isRunning {
            do { try engine.start() } catch {
                log.error("engine.start: \(String(describing: error), privacy: .public)")
                return
            }
        }

        let startFrame = AVAudioFramePosition(currentTime * Self.sampleRate)
        let total = AVAudioFramePosition(buffer.frameLength)
        if startFrame >= total {
            // EOF — rewind on next play
            currentTime = 0
            return
        }

        let onDone: AVAudioNodeCompletionHandler = { [weak self] in
            Task { @MainActor in self?.finished() }
        }
        let toPlay: AVAudioPCMBuffer
        if startFrame == 0 {
            toPlay = buffer
        } else if let slice = Self.slice(buffer, from: startFrame) {
            toPlay = slice
        } else {
            toPlay = buffer
        }
        node.scheduleBuffer(toPlay, completionHandler: onDone)

        resumeAnchor = currentTime
        nodeStartFrame = node.lastRenderTime?.sampleTime ?? 0
        node.play()
        isPlaying = true
    }

    /// AVAudioPlayerNode's `scheduleSegment` only accepts AVAudioFile,
    /// not AVAudioPCMBuffer. To support mid-buffer resume we materialize
    /// a one-off copy from the requested frame onward. ~5MB for a 5-min
    /// voice note; freed when the node finishes consuming it.
    private static func slice(_ src: AVAudioPCMBuffer,
                              from startFrame: AVAudioFramePosition)
        -> AVAudioPCMBuffer?
    {
        let total = AVAudioFramePosition(src.frameLength)
        guard startFrame < total else { return nil }
        let remaining = AVAudioFrameCount(total - startFrame)
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format,
                                          frameCapacity: remaining),
              let srcData = src.floatChannelData,
              let dstData = dst.floatChannelData else { return nil }
        dst.frameLength = remaining
        let channels = Int(src.format.channelCount)
        for c in 0..<channels {
            dstData[c].update(from: srcData[c] + Int(startFrame),
                              count: Int(remaining))
        }
        return dst
    }

    func pause() {
        guard let node else { return }
        currentTime = renderedTime()
        node.pause()
        isPlaying = false
    }

    /// Stops playback and releases the engine. Mirrors AudioPlayerView's
    /// onDisappear contract — the FigPlayer registry kept resources for
    /// 60 s after AVPlayer release; AVAudioEngine releases synchronously
    /// once `stop()` returns.
    func teardown() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let was = isPlaying
        node?.stop()
        currentTime = max(0, min(time, duration))
        if was { play() }
    }

    /// Updates `currentTime` from the render clock. Call from the host
    /// view's polling timer (same 200 ms cadence as the AVPlayer path).
    func tick() {
        guard isPlaying else { return }
        currentTime = renderedTime()
    }

    private func renderedTime() -> TimeInterval {
        guard let node,
              let last = node.lastRenderTime,
              let pTime = node.playerTime(forNodeTime: last) else {
            return currentTime
        }
        let elapsed = Double(pTime.sampleTime - nodeStartFrame) / Self.sampleRate
        return min(duration, resumeAnchor + max(0, elapsed))
    }

    private func finished() {
        isPlaying = false
        currentTime = 0
    }
}
