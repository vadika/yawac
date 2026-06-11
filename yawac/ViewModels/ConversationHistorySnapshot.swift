import AppKit
import Foundation

/// `NSImage` lacks an unconditional `Sendable` conformance (its
/// representations array is mutable). Snapshot preheat produces
/// pre-decoded NSImages off-MainActor and hands them to MainActor's
/// `applyHistorySnapshot` for a one-way commit; no further mutation
/// happens after the snapshot is built, so the unchecked conformance
/// is safe in this single-producer / single-consumer flow.
struct PreheatImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

/// Immutable result of a background `ConversationViewModel` history /
/// load-earlier build. Carries everything the view needs to render the
/// chat after a single MainActor commit step. See
/// `ConversationViewModel.buildHistorySnapshot` for the producer and
/// `applyHistorySnapshot` for the consumer.
struct ConversationHistorySnapshot: Sendable {
    let messages: [UIMessage]
    let receiptStatus: [String: UIMessage.Status]
    let reactionsBySender: [String: [String: String]]  // msgID → senderJID → emoji
    let pollVotes: [String: [String: Set<String>]]      // msgID → optionHash → voterJIDs
    let localPaths: [String: String]
    /// Pre-decoded `NSImage`s for the last ~30 image/sticker rows
    /// with on-disk media — keyed by absolute path. Consumed by
    /// `ThumbnailCache.preheat(_:)` BEFORE `self.messages = ...` so
    /// the LazyVStack's first paint of visible image bubbles hits the
    /// in-memory cache synchronously instead of starting from a
    /// placeholder. Decoded off-MainActor inside the snapshot builder
    /// (was raw `Data` until F39+; carrying `NSImage` here is safe
    /// because `NSImage` ships its bytes across actors fine and the
    /// snapshot is consumed once on MainActor). Capped at 30 entries
    /// / 5 MB per source file by the builder.
    let preheatThumbs: [String: PreheatImage]
    /// Pre-decoded video thumbnail `NSImage`s for the last ~30 video
    /// rows whose SHA disk cache already exists — keyed by the
    /// SOURCE video file path (NOT the SHA PNG path; the cache key
    /// matches what `ThumbnailCache.videoImage(forPath:)` is called
    /// with at body time). Consumed by
    /// `ThumbnailCache.preheatVideo(_:)` BEFORE `self.messages = ...`.
    /// Decoded off-MainActor inside the snapshot builder. Capped at
    /// 30 entries / 5 MB per source file by the builder.
    let preheatVideoThumbs: [String: PreheatImage]
    /// Pre-decoded avatar `NSImage`s for the distinct senders in the
    /// last visible message window — keyed by canonical JID cache
    /// key. The highest-impact preheat since every message row has
    /// an `AvatarView` and group threads contain many distinct
    /// senders. Consumed by `ThumbnailCache.preheatAvatar(_:)`
    /// BEFORE `self.messages = ...` (F12). Decoded off-MainActor
    /// inside the snapshot builder. Capped at 60 entries / 5 MB per
    /// source file by the builder.
    let preheatAvatars: [String: PreheatImage]
    let initialAnchorID: String?
    let unreadInboundIDs: Set<String>
    /// Messages whose media is still missing and need a download kicked
    /// once the snapshot lands on MainActor.
    let downloadTargets: [DownloadTarget]
    /// Per-row downloadErrors to merge (currently used for missing-ref
    /// and expired-media surfacing).
    let downloadErrors: [String: String]
    /// Messages whose media is server-expired (auto-refetch candidates).
    let expiredOnLoad: [ExpiredEntry]
    /// Diagnostic ms timings for `perfLog`.
    let timings: Timings

    struct DownloadTarget: Sendable {
        let id: String
        let kind: String
        let refJSON: String
    }
    struct ExpiredEntry: Sendable {
        let id: String
        let timestamp: Date
    }
    struct Timings: Sendable {
        let scrubMs: Double
        let fetchMs: Double
        let mapMs: Double
        let totalMs: Double
        let rowCount: Int
    }
}

/// Subset of `ConversationHistorySnapshot` used by the load-earlier
/// path. Reactions / poll votes are already hydrated on MainActor, so
/// the earlier snapshot only carries the freshly-paged message window.
struct ConversationEarlierSnapshot: Sendable {
    let messages: [UIMessage]
}
