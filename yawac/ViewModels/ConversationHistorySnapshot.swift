import Foundation

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
    /// Raw file bytes for the last ~30 image/sticker rows with on-disk
    /// media — keyed by absolute path. Consumed by
    /// `ThumbnailCache.preheat(_:)` BEFORE `self.messages = ...` so the
    /// LazyVStack's first paint of visible image bubbles hits the
    /// in-memory cache synchronously instead of starting from a
    /// placeholder. Capped at 30 entries / 5 MB per file by the
    /// builder; using `Data` (not `NSImage`) keeps the snapshot
    /// `Sendable`.
    let preheatThumbs: [String: Data]
    /// Raw PNG bytes for the last ~30 video rows whose SHA disk cache
    /// already exists — keyed by the SOURCE video file path (NOT the
    /// SHA PNG path; the cache key matches what
    /// `ThumbnailCache.videoImage(forPath:)` is called with at body
    /// time). Consumed by `ThumbnailCache.preheatVideo(_:)` BEFORE
    /// `self.messages = ...` so the LazyVStack's first paint of video
    /// bubbles in the visible window hits the in-memory cache
    /// synchronously instead of flashing a gray placeholder for one
    /// frame. Capped at 30 entries / 5 MB per file by the builder.
    let preheatVideoThumbs: [String: Data]
    /// Raw avatar JPEG bytes for the distinct senders in the last
    /// visible message window — keyed by canonical JID cache key. The
    /// highest-impact preheat since every message row has an
    /// `AvatarView` and group threads contain many distinct senders.
    /// Consumed by `ThumbnailCache.preheatAvatar(_:)` BEFORE
    /// `self.messages = ...` so the first paint hits the in-memory
    /// cache (F12). Capped at 60 entries / 5 MB per file by the
    /// builder.
    let preheatAvatars: [String: Data]
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
