import COpus
import Foundation

/// Thin Swift wrapper around libopusenc's OggOpusEnc.
/// Writes a single mono / stereo Opus stream wrapped in Ogg directly to a
/// file path. Designed for one-shot voice-note recording.
public final class OpusFileEncoder {
    public enum Error: Swift.Error {
        case createFailed(Int32)
        case writeFailed(Int32)
        case drainFailed(Int32)
    }

    private var enc: OpaquePointer?
    private var comments: OpaquePointer?
    public let sampleRate: Int32
    public let channels: Int32

    /// Opens an Ogg-Opus file at `url`. 16 kHz mono is the WhatsApp voice-note format.
    public init(url: URL, sampleRate: Int32 = 16_000, channels: Int32 = 1) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.comments = ope_comments_create()
        var status: Int32 = 0
        let path = url.path
        let enc = path.withCString { cstr in
            ope_encoder_create_file(cstr, comments, sampleRate, channels, 0, &status)
        }
        guard let enc, status == 0 else {
            ope_comments_destroy(comments)
            throw Error.createFailed(status)
        }
        self.enc = enc
    }

    /// Appends interleaved Float32 PCM samples in [-1, 1].
    public func write(_ samples: [Float]) throws {
        guard let enc else { return }
        let frames = Int32(samples.count) / channels
        let status = samples.withUnsafeBufferPointer { buf -> Int32 in
            ope_encoder_write_float(enc, buf.baseAddress, frames)
        }
        if status != 0 { throw Error.writeFailed(status) }
    }

    /// Flushes pending packets, finalizes the Ogg stream, releases resources.
    public func finish() throws {
        guard let enc else { return }
        let status = ope_encoder_drain(enc)
        if status != 0 { throw Error.drainFailed(status) }
        ope_encoder_destroy(enc)
        self.enc = nil
        ope_comments_destroy(comments)
        comments = nil
    }

    deinit {
        if enc != nil {
            ope_encoder_destroy(enc)
            ope_comments_destroy(comments)
        }
    }
}
