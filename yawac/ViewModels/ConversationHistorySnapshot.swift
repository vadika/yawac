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
