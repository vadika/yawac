import Foundation
import NaturalLanguage

/// On-device, synchronous language detection. Wraps Apple's
/// `NLLanguageRecognizer` with a two-tier cache (memory + disk) so the
/// chat UI can call this once per re-render without measurable cost.
///
/// SwiftUI bodies re-evaluate constantly (timeline generation bumps,
/// thumbnail cache revisions, receipt updates, etc.). Each visible
/// message that goes through `translatableText` calls
/// `LanguageDetector.detect` on every body eval. Without sufficient
/// caching, large chats (status@broadcast, group threads) exceed the
/// memory cache and re-spawn `NLLanguageRecognizer` on every scroll.
///
/// Three changes versus the pre-F23 design:
/// 1. Memory cache `countLimit` bumped 64 → 512 so the visible window
///    plus recent scroll history stays resident.
/// 2. Negative results (nil because the recognizer's confidence was
///    below threshold) are cached too via a sentinel string. Without
///    this, every body eval re-ran the full `processString` for any
///    text the recognizer couldn't classify confidently.
/// 3. Cache keys are the actual `NSString` text instead of an `Int`
///    hashValue. `String.hashValue` is per-process randomized and has
///    collision risk; using the text itself eliminates both. Memory
///    impact is bounded by the per-message text length × 512.
/// 4. Disk cache (~/Library/Caches/<bundle>/LanguageDetector.json)
///    persists detections across launches. The file is loaded once at
///    first call and written back on a debounced timer when new
///    entries land. Keeps cold-launch scrolls cheap.
enum LanguageDetector {
    /// Sentinel BCP-47 code stored in the cache to remember "we tried
    /// this text and `NLLanguageRecognizer` couldn't classify it
    /// confidently". Empty string can't be a real BCP-47 code; using
    /// the special "-" keeps the cache value strictly `NSString`.
    private static let negativeSentinel: NSString = "-"

    private static let cache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 512
        return c
    }()

    /// Disk-cache state. `diskLoaded` flips true after the first
    /// `loadDiskCache()` runs so we don't re-read the file on every
    /// call. `dirty` flips true when a new entry lands; the debounced
    /// flush picks it up on the next fire and writes back to disk.
    private static let diskQueue = DispatchQueue(label: "yawac.LanguageDetector.disk")
    nonisolated(unsafe) private static var diskLoaded = false
    nonisolated(unsafe) private static var diskMap: [String: String] = [:]
    nonisolated(unsafe) private static var dirty = false
    nonisolated(unsafe) private static var pendingWriteTimer: DispatchSourceTimer?

    /// Minimum confidence the recognizer must report before we
    /// trust the top hypothesis. Empirically 0.6 filters out
    /// short-string false positives without rejecting normal
    /// sentences.
    private static let minConfidence: Double = 0.6

    /// Minimum visible character count below which detection is
    /// considered unreliable.
    private static let minChars: Int = 10

    /// Returns the BCP-47 code (e.g. `"de"`, `"fi"`, `"en"`) of the
    /// dominant language in `text`, or `nil` if the text is too short,
    /// has no script characters, or the recognizer's confidence is
    /// below threshold. Cached forever (memory + disk).
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars else { return nil }

        let key = trimmed as NSString
        if let cached = cache.object(forKey: key) {
            return cached == negativeSentinel ? nil : (cached as String)
        }

        // Lazy first-time disk load. Cheap when file doesn't exist.
        ensureDiskLoaded()
        if let fromDisk = diskQueue.sync(execute: { diskMap[trimmed] }) {
            let ns = fromDisk as NSString
            cache.setObject(ns, forKey: key)
            return fromDisk == "-" ? nil : fromDisk
        }

        let r = NLLanguageRecognizer()
        r.processString(trimmed)
        let result: String?
        if let top = r.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
           top.value >= minConfidence {
            result = top.key.rawValue
        } else {
            result = nil
        }

        cache.setObject((result ?? "-") as NSString, forKey: key)
        diskQueue.async {
            diskMap[trimmed] = result ?? "-"
            dirty = true
            scheduleDiskFlush()
        }
        return result
    }

    // MARK: - Disk cache

    private static var diskURL: URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "yawac"
        return caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("LanguageDetector.json")
    }

    private static func ensureDiskLoaded() {
        diskQueue.sync {
            guard !diskLoaded else { return }
            diskLoaded = true
            guard let url = diskURL,
                  let data = try? Data(contentsOf: url),
                  let map = try? JSONDecoder().decode([String: String].self, from: data)
            else { return }
            diskMap = map
        }
    }

    /// Debounced 2 s write-back. Called from the disk queue with a new
    /// entry pending. Replaces any previously-scheduled timer so bursts
    /// of detections settle into one disk write.
    private static func scheduleDiskFlush() {
        pendingWriteTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: diskQueue)
        t.schedule(deadline: .now() + .seconds(2))
        t.setEventHandler {
            guard dirty else { return }
            dirty = false
            guard let url = diskURL else { return }
            let snapshot = diskMap
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        t.resume()
        pendingWriteTimer = t
    }
}
