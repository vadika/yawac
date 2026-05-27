import AVFoundation
import Foundation
import Observation
import Opus
import OSLog

private let log = Logger(subsystem: "dev.vadikas.yawac", category: "voice")

/// Records mic input → Ogg-Opus file at 16 kHz mono. Publishes live
/// elapsed time + UI-friendly normalized levels for the recording bar.
/// Push-and-hold lifecycle: `start()` on press, `finish()` on release,
/// `cancel()` on drag-out.
@MainActor
@Observable
final class VoiceRecorder {
    enum State { case idle, recording, finalizing, error }

    struct Result {
        let url: URL
        let durationSec: Int
        let waveform: Data   // 64-byte WA digest
    }

    enum Failure: Error {
        case permissionDenied
        case engineStart(Error)
        case converterUnavailable
        case opusInit(Int32)
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var lastError: Failure?

    static let maxDuration: TimeInterval = 300       // WhatsApp cap
    private static let targetSampleRate: Double = 16_000
    private static let levelWindow = 80              // ~last 4s @ 50Hz

    private var engine: AVAudioEngine?
    private var encoder: OpusFileEncoder?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var outputURL: URL?
    private var startedAt: Date?
    private var tickTimer: Timer?

    private let audioQueue = DispatchQueue(label: "yawac.voice-recorder",
                                           qos: .userInitiated)
    private var waveformSamples: [Float] = []        // audioQueue-owned

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() {
        log.info("start() called; state=\(String(describing: self.state), privacy: .public)")
        guard state == .idle else { log.info("start() bail: not idle"); return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-\(UUID().uuidString).ogg")
        let enc: OpusFileEncoder
        do {
            enc = try OpusFileEncoder(url: url,
                                      sampleRate: Int32(Self.targetSampleRate),
                                      channels: 1)
        } catch let OpusFileEncoder.Error.createFailed(code) {
            lastError = .opusInit(code); state = .error; return
        } catch {
            lastError = .opusInit(-1); state = .error; return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // inputFormat (not outputFormat) returns the hardware native
        // format and is valid before engine.prepare/start. outputFormat
        // is unconfigured until the engine wires up the bus, which
        // returns sampleRate=0 in that window.
        let inputFormat = input.inputFormat(forBus: 0)
        log.info("inputFormat sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inputFormat, to: target)
        else {
            log.error("format/converter unavailable; bailing")
            try? enc.finish()
            try? FileManager.default.removeItem(at: url)
            lastError = .converterUnavailable; state = .error; return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buf, _ in
            self?.audioQueue.async { [weak self] in self?.process(buf) }
        }

        do {
            try engine.start()
            log.info("engine.start ok")
        } catch {
            log.error("engine.start FAILED: \(String(describing: error), privacy: .public)")
            input.removeTap(onBus: 0)
            try? enc.finish()
            try? FileManager.default.removeItem(at: url)
            lastError = .engineStart(error); state = .error; return
        }

        self.engine = engine
        self.encoder = enc
        self.converter = conv
        self.targetFormat = target
        self.outputURL = url
        self.startedAt = Date()
        self.elapsed = 0
        self.levels.removeAll(keepingCapacity: true)
        self.audioQueue.async { [weak self] in self?.waveformSamples.removeAll() }
        self.state = .recording
        log.info("state = .recording")

        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.tickTimer = t
    }

    private func tick() {
        guard state == .recording, let s = startedAt else { return }
        elapsed = Date().timeIntervalSince(s)
        if elapsed >= Self.maxDuration {
            // Auto-stop at cap; treat as a normal finish — caller observes
            // state transitioning to .idle with a non-nil consume() result.
            autoStopAtCap()
        }
    }

    private var autoStopResult: Result?
    private var capturedFrames: Int = 0
    private func autoStopAtCap() {
        if let r = try? finishInternal() { autoStopResult = r }
    }

    /// Pop the auto-stop result if the cap fired (and caller hasn't
    /// already called `finish()`).
    func consumeAutoStop() -> Result? {
        defer { autoStopResult = nil }
        return autoStopResult
    }

    /// Called by the audio queue. `buf` is from the engine tap thread but
    /// has been retained by `async`.
    private func process(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter, let target = targetFormat,
              let enc = encoder
        else { return }

        let ratio = target.sampleRate / buf.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)
        else { return }

        var err: NSError?
        var consumed = false
        // Use .noDataNow (not .endOfStream) when the input block has
        // nothing more for THIS convert() call. .endOfStream tells the
        // converter "no more input ever" and finalizes its resampler
        // state — subsequent calls produce near-zero frames. With
        // .noDataNow the converter keeps its internal filter delay
        // state across calls, which is what we want for streaming.
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        if err != nil { return }

        let n = Int(out.frameLength)
        guard n > 0, let ch = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: n))
        do {
            try enc.write(samples)
            capturedFrames += n
        } catch {
            log.error("encode error: \(String(describing: error), privacy: .public)")
        }

        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrtf(sumSq / Float(n))
        let db = 20 * log10f(max(rms, 1e-6))
        let norm = max(0, min(1, (db + 60) / 60))   // -60dB → 0, 0dB → 1
        waveformSamples.append(norm)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.levels.append(norm)
            if self.levels.count > Self.levelWindow {
                self.levels.removeFirst(self.levels.count - Self.levelWindow)
            }
        }
    }

    /// Stop, finalize the Ogg stream, return the result. Caller owns the
    /// temp file from here on.
    func finish() throws -> Result {
        return try finishInternal()
    }

    private func finishInternal() throws -> Result {
        guard state == .recording, let url = outputURL else {
            throw Failure.engineStart(NSError(domain: "VoiceRecorder",
                                              code: -1))
        }
        state = .finalizing
        tickTimer?.invalidate(); tickTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // Drain any buffered tap callbacks before closing the encoder.
        audioQueue.sync {}
        do {
            try encoder?.finish()
        } catch {
            // Best-effort: keep the file; the OS will recover from a
            // partial Ogg page on most decoders.
        }
        let dur = max(1, Int(elapsed.rounded()))
        let wf = downsampledWaveform()
        let result = Result(url: url, durationSec: dur, waveform: wf)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        log.info("finish: capturedFrames=\(self.capturedFrames) durSec=\(dur) oggBytes=\(size ?? -1) waveformBytes=\(wf.count) path=\(url.path, privacy: .public)")
        capturedFrames = 0
        reset()
        return result
    }

    func cancel() {
        guard state == .recording || state == .finalizing else {
            reset(); return
        }
        tickTimer?.invalidate(); tickTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        audioQueue.sync {}
        try? encoder?.finish()
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        reset()
    }

    private func reset() {
        engine = nil
        encoder = nil
        converter = nil
        targetFormat = nil
        outputURL = nil
        startedAt = nil
        elapsed = 0
        levels.removeAll()
        audioQueue.async { [weak self] in self?.waveformSamples.removeAll() }
        state = .idle
    }

    /// Build the 64-byte 6-bit log-meter digest WhatsApp uses for
    /// AudioMessage.Waveform. Each byte = peak normalized level in that
    /// window mapped to 0..63.
    private func downsampledWaveform() -> Data {
        let target = 64
        let snapshot = audioQueue.sync { waveformSamples }
        guard !snapshot.isEmpty else {
            return Data(repeating: 0, count: target)
        }
        var bytes = [UInt8](repeating: 0, count: target)
        let step = Double(snapshot.count) / Double(target)
        for i in 0..<target {
            let lo = Int(Double(i) * step)
            let hi = min(snapshot.count, max(lo + 1, Int(Double(i + 1) * step)))
            var peak: Float = 0
            for j in lo..<hi where j < snapshot.count {
                peak = max(peak, snapshot[j])
            }
            bytes[i] = UInt8(max(0, min(63, Int(peak * 63))))
        }
        return Data(bytes)
    }
}
