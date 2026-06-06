import Foundation

/// Minimal Ogg container reader. Walks the page table and reconstructs
/// packets via the segment lacing rules from RFC 3533 §6. Designed for
/// the single-stream Ogg-Opus files WhatsApp produces — chained streams
/// (where a new BOS appears mid-file) and multiplexed serials are not
/// supported. Voice notes never use either.
struct OggOpusDemuxer {
    enum Failure: Error {
        case notOgg
        case truncated
    }

    /// Decoded packets in order. The first is the OpusHead identification
    /// header; the second is OpusTags; the rest are audio packets fed to
    /// `opus_decode_float`.
    let packets: [Data]

    /// Pre-skip samples to discard at the start of decoded output, parsed
    /// from OpusHead bytes 10..11 (uint16 LE) per RFC 7845 §5.1. Always
    /// at 48 kHz regardless of input rate.
    let preSkip: Int

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var out: [Data] = []
        var pending = Data()
        var i = 0
        while i + 27 <= data.count {
            // OggS magic
            guard data[i] == 0x4F, data[i + 1] == 0x67,
                  data[i + 2] == 0x67, data[i + 3] == 0x53 else {
                throw Failure.notOgg
            }
            let nSeg = Int(data[i + 26])
            let segTable = i + 27
            let pageData = segTable + nSeg
            guard pageData <= data.count else { throw Failure.truncated }

            var p = pageData
            for s in 0..<nSeg {
                let len = Int(data[segTable + s])
                guard p + len <= data.count else { throw Failure.truncated }
                if len > 0 {
                    pending.append(data.subdata(in: p..<(p + len)))
                }
                p += len
                // A lacing value < 255 terminates a packet; == 255 means
                // the packet spans into the next segment (and possibly
                // the next page via the continuation flag).
                if len < 255 {
                    out.append(pending)
                    pending = Data()
                }
            }
            i = p
        }

        self.packets = out

        // OpusHead is the first packet on the BOS page. Bytes 0..7 = "OpusHead".
        // Layout per RFC 7845: magic[8] version[1] channels[1] preSkip[2 LE]
        // inputRate[4 LE] gain[2 LE] mapping[1] …
        if let head = out.first, head.count >= 12,
           head[0] == 0x4F, head[1] == 0x70, head[2] == 0x75, head[3] == 0x73,
           head[4] == 0x48, head[5] == 0x65, head[6] == 0x61, head[7] == 0x64 {
            self.preSkip = Int(head[10]) | (Int(head[11]) << 8)
        } else {
            self.preSkip = 0
        }
    }

    /// Magic-byte sniff for the OggS container marker at file offset 0.
    /// More reliable than extension matching — the on-disk path WhatsApp
    /// chooses for voice notes isn't always `.ogg` (some media-cache
    /// branches drop the extension entirely), but the file body is
    /// always RFC 3533 Ogg. ~10 µs.
    static func isOggFile(url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 4), data.count == 4 else {
            return false
        }
        return data[0] == 0x4F && data[1] == 0x67
            && data[2] == 0x67 && data[3] == 0x53
    }

    /// Cheap duration probe that avoids decoding any audio packets.
    /// Maps the file, walks page headers, and reads the granule_position
    /// of the last page — which by spec is the cumulative output sample
    /// count at 48 kHz. Returns nil for malformed files. ~200 µs on a
    /// 5-minute voice note.
    static func peekDurationSeconds(url: URL) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        var lastGranule: UInt64?
        var preSkip: UInt64 = 0
        var sawHead = false
        var i = 0
        while i + 27 <= data.count {
            guard data[i] == 0x4F, data[i + 1] == 0x67,
                  data[i + 2] == 0x67, data[i + 3] == 0x53 else { return nil }
            // granule_position is bytes 6..13, little-endian uint64.
            var g: UInt64 = 0
            for k in 0..<8 { g |= UInt64(data[i + 6 + k]) << (8 * k) }
            if g != 0xFFFF_FFFF_FFFF_FFFF { lastGranule = g }
            let nSeg = Int(data[i + 26])
            var dataLen = 0
            let segTable = i + 27
            guard segTable + nSeg <= data.count else { return nil }
            for s in 0..<nSeg { dataLen += Int(data[segTable + s]) }
            let pageStart = segTable + nSeg
            // Capture pre-skip from the OpusHead packet (always on the
            // BOS page, payload byte offsets 10..11) the first time
            // through so we can subtract it from the final granule.
            if !sawHead, pageStart + 12 <= data.count,
               data[pageStart] == 0x4F, data[pageStart + 1] == 0x70,
               data[pageStart + 2] == 0x75, data[pageStart + 3] == 0x73,
               data[pageStart + 4] == 0x48, data[pageStart + 5] == 0x65,
               data[pageStart + 6] == 0x61, data[pageStart + 7] == 0x64 {
                preSkip = UInt64(data[pageStart + 10])
                    | (UInt64(data[pageStart + 11]) << 8)
                sawHead = true
            }
            i = pageStart + dataLen
        }
        guard let total = lastGranule, total >= preSkip else { return nil }
        return TimeInterval(total - preSkip) / 48_000.0
    }
}
