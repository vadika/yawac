import Foundation
import Observation
import os
import SwiftData
import UniformTypeIdentifiers

private let perfLog = Logger(subsystem: "dev.vadikas.yawac.yawac",
                             category: "perf")

/// A file the user picked but hasn't sent yet — staged in the composer so a
/// caption can be added and the set edited before sending.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: String   // image | video | audio | document
    var viewOnce: Bool = false
}

@Observable @MainActor
final class ConversationViewModel {
    let chatJID: String
    var messages: [UIMessage] = []
    /// O(1) dedupe mirror of `messages.map(\.id)`. Maintained at every
    /// `messages.append/insert/=` site so `ingest` can short-circuit
    /// duplicates without walking the array. `@ObservationIgnored` —
    /// it's a lookup index, not visible state.
    @ObservationIgnored private var messageIDs: Set<String> = []
    /// F8: 50ms ingest coalescer. Bursts of inbound BridgeMessage events
    /// (history-sync, reconnect drain) used to trigger one
    /// `messages.append` + `invalidateTimeline` per event — a full
    /// SwiftUI re-render and timeline rebuild per row. We now queue
    /// arrivals here and flush once per 50ms window: single batch
    /// append, single `invalidateTimeline`. Mirrors the F3 pattern in
    /// ChatListViewModel.
    @ObservationIgnored private var pendingIngest: [BridgeMessage] = []
    @ObservationIgnored private var pendingIngestIDs: Set<String> = []
    @ObservationIgnored private var pendingIngestFlush: Task<Void, Never>?
    var draft: String = "" {
        didSet { scheduleDraftSave() }
    }
    var peerTyping: Bool = false
    var receiptStatus: [String: UIMessage.Status] = [:]
    var localPaths: [String: String] = [:]
    /// Attachments staged in the composer, awaiting a caption / send.
    var pendingAttachments: [PendingAttachment] = []
    /// Locations staged in the composer alongside files / contacts. Kept
    /// in a parallel array (rather than folded into `PendingAttachment`)
    /// because the file-staging struct is URL-only — locations have no
    /// on-disk artifact.
    var pendingLocations: [LocationPayload] = []
    /// Contact cards staged in the composer alongside files / locations.
    var pendingContacts: [ContactPayload] = []
    /// Disappearing-messages timer (seconds) to thread through outbound
    /// sends. Defaults to 0 (off); set by external wiring once the
    /// chat-level disappearing state lands in CVM (T26-T28). Wiring it
    /// here now lets every send call thread the field consistently.
    var ephemeralExpirationSeconds: Int32 = 0
    // Per-message reactions: targetMessageID -> senderJID -> emoji.
    // Nested so removing/updating a sender's reaction is O(1).
    var reactionsBySender: [String: [String: String]] = [:]
    // Per-poll vote tally: pollMessageID -> optionHash -> Set<voterJID>.
    var pollVotes: [String: [String: Set<String>]] = [:]
    var downloadErrors: [String: String] = [:]
    let client: WAClient
    private let context: ModelContext?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    // One retry-request per message id per session — avoids hammering the
    // phone with redundant SendMediaRetryReceipt calls if download retries
    // keep failing.
    private var retriesRequested: Set<String> = []
    /// Set once per chat session after an auto-backfill burst for
    /// expired media. Stops the loadHistory pass from re-firing the
    /// burst on every refresh.
    private var didAutoRefetchExpired = false
    // On-demand older-history state. `loadingOlder` is private(set) so the
    // view can read it for the spinner; `olderUnavailable` is set when a
    // RequestOlderHistory call produced no new rows within the wait window,
    // letting the UI hide the "Load earlier" button.
    private(set) var loadingOlder = false
    var olderUnavailable = false
    private(set) var refreshingPolls = false
    var replyTarget: UIMessage?
    var editTarget:  UIMessage?
    /// Surfaces fire-and-forget error to the view (toast/banner). View
    /// clears after display.
    var transientError: String?

    var pendingScrollToID: String?
    var highlightedID: String?
    /// Forward selection mode. `forwardSelection` holds the chosen message ids.
    var forwardSelecting = false
    var forwardSelection: Set<String> = []

    /// Drives the PollComposerView modal sheet. Toggled by the composer's
    /// "+" menu and by Cancel / on-success inside the sheet.
    var showPollComposer: Bool = false

    /// Inbound message ids that still owe a read receipt — populated
    /// from `PersistedChat.unread` (last-N inbound rows) at history
    /// load and from `ingest` on the fly. `markVisibleAsRead` drains
    /// entries as their rows clear the 2s viewport-dwell threshold.
    var unreadInboundIDs: Set<String> = []
    /// Back-ref to the chat list so mutations (edit/revoke/delete-for-me)
    /// can push an updated preview to the sidebar. Set by ConversationView
    /// when the chat becomes active.
    weak var chatList: ChatListViewModel?

    // MARK: - Sectioned timeline cache
    //
    // ConversationView used to call `timeline()` from within `ForEach`,
    // walking `messages` and building a fresh `[TimelineItem]` (with
    // per-day `dateHeader`s) on every body evaluation — O(n) per redraw.
    // The same view also computed `messageRevisionToken` by reducing
    // every UIMessage to count `starredAt != nil`, another O(n) pass.
    //
    // We now cache the sectioned array and invalidate it lazily via a
    // generation counter that is bumped only when the timeline's inputs
    // (`messages`, `localPaths`, or `starredAt`) actually change. The
    // cache-hit path is O(1) (Int compare).
    //
    // `timelineGeneration` is observable so views can react to
    // invalidations (ChatInfoView reads it as `messageRevision`); the
    // backing array + last-seen generation are
    // `@ObservationIgnored` so reading/writing the cache itself does
    // *not* trigger a view re-eval.
    @ObservationIgnored private var cachedTimeline: [TimelineItem] = []
    @ObservationIgnored private var cachedTimelineGen: Int = -1
    private(set) var timelineGeneration: Int = 0

    /// Returns the sectioned (date-headers + messages) timeline, served
    /// from cache when the generation hasn't moved. Rebuilds only when
    /// `invalidateTimeline()` has been called since the last build.
    func timeline() -> [TimelineItem] {
        if cachedTimelineGen == timelineGeneration {
            return cachedTimeline
        }
        let cal = Calendar.current
        var out: [TimelineItem] = []
        out.reserveCapacity(messages.count + 8)
        var lastDay: DateComponents?
        for m in messages {
            let day = cal.dateComponents([.year, .month, .day], from: m.timestamp)
            if day != lastDay {
                if let header = cal.date(from: day) {
                    out.append(.dateHeader(header))
                }
                lastDay = day
            }
            out.append(.message(m))
        }
        cachedTimeline = out
        cachedTimelineGen = timelineGeneration
        return out
    }

    /// Bumps the timeline generation counter. Call after every mutation
    /// to `messages`, `localPaths`, or any per-message field that
    /// influences the displayed timeline (e.g. `starredAt`,
    /// `locallyDeleted`, `revokedAt`, `editedAt`, `pinnedAt`,
    /// `viewOnceLocked`).
    private func invalidateTimeline() {
        timelineGeneration &+= 1
    }

    // MARK: - In-chat find bar
    var messageIndex: MessageIndex = .shared
    var findActive: Bool = false {
        didSet {
            if !findActive {
                findQuery = ""
                findHits = []
                findCurrentIdx = 0
            }
        }
    }
    var findQuery: String = "" {
        didSet { scheduleFind() }
    }
    /// Optional filter knobs applied on top of the find-bar query.
    /// Mutating any field re-runs the search (no debounce — filter
    /// changes are tap-driven not key-stroke driven).
    var findFilters: MessageIndex.SearchFilters = .init() {
        didSet { if oldValue != findFilters { scheduleFind() } }
    }
    var findHits: [MessageIndex.Hit] = []
    var findCurrentIdx: Int = 0
    var findHitIDs: Set<String> { Set(findHits.map(\.messageID)) }

    /// Sender (jid, displayName) pairs from the FTS index for this
    /// chat. Drives the in-chat Sender filter picker. The chip value is
    /// the JID so filter equality survives push-name changes; the label
    /// resolves via `session.displayName` when known, falling back to
    /// the indexed push name.
    func knownSendersInChat(session: SessionViewModel) -> [(jid: String, name: String)] {
        return messageIndex.distinctSendersInChat(jid: chatJID).map { row in
            let resolved = session.displayName(for: row.jid)
            let label = resolved.isEmpty ? row.name : resolved
            return (jid: row.jid, name: label)
        }
    }

    private var findTask: Task<Void, Never>?
    private let findDebounceMs: Int = 120

    private func scheduleFind() {
        findTask?.cancel()
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty && findFilters.isEmpty {
            findHits = []
            findCurrentIdx = 0
            return
        }
        let jid = chatJID
        let idx = messageIndex
        let f = findFilters
        findTask = Task { [weak self, findDebounceMs] in
            try? await Task.sleep(for: .milliseconds(findDebounceMs))
            guard let self, !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                idx.searchInChat(jid: jid, query: q, filters: f)
            }.value
            guard !Task.isCancelled else { return }
            self.findHits = hits
            self.findCurrentIdx = 0
            if let first = hits.first { self.pendingScrollToID = first.messageID }
        }
    }

    /// Synchronous test seam — bypasses the debounce.
    func runFindForTest() async {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty && findFilters.isEmpty {
            findHits = []; findCurrentIdx = 0; return
        }
        let idx = messageIndex; let jid = chatJID
        let f = findFilters
        let hits = await Task.detached(priority: .userInitiated) {
            idx.searchInChat(jid: jid, query: q, filters: f)
        }.value
        findHits = hits
        findCurrentIdx = 0
    }

    func findNext() {
        guard !findHits.isEmpty else { return }
        findCurrentIdx = (findCurrentIdx + 1) % findHits.count
        pendingScrollToID = findHits[findCurrentIdx].messageID
    }

    func findPrev() {
        guard !findHits.isEmpty else { return }
        findCurrentIdx = (findCurrentIdx - 1 + findHits.count) % findHits.count
        pendingScrollToID = findHits[findCurrentIdx].messageID
    }

    func jumpToQuoted(id: String) async {
        // F36: always re-window when the loaded slice is large enough
        // that scrollTo would beachball. Below the jumpWindowSize
        // ceiling the LazyVStack handles cross-chat scrolls fine —
        // skip the rebuild and use the existing fast path.
        if messages.count <= Self.jumpWindowSize {
            if messages.contains(where: { $0.id == id }) {
                pendingScrollToID = id
                return
            }
        } else {
            // Re-window: replace `messages` with a smaller slice
            // centered on the target's timestamp. Subsequent scrollTo
            // is then fast because LazyVStack only has to compute
            // ~jumpWindowSize layouts instead of 10k+.
            if await rewindowAround(targetID: id) {
                pendingScrollToID = id
                return
            }
            // Fall through to the inject-single-row fallback below if
            // the target persisted row can't be found.
        }
        // Row is outside the currently-loaded window — try to fetch from
        // SwiftData and inject. (loadHistory pages from newest; the quoted
        // target is by id, not by position.)
        guard let context else {
            transientError = "Original not available"
            return
        }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id })
        guard let p = try? context.fetch(descriptor).first else {
            transientError = "Original not available"
            return
        }
        let body: UIMessage.Body
        switch p.kind {
        case "text":
            body = .text(p.text ?? "")
        case "image", "video", "audio", "document", "sticker":
            body = .media(kind: p.kind, caption: p.mediaCaption,
                          fileName: p.mediaFileName, localPath: p.mediaPath,
                          waveform: p.audioWaveform, isPTT: p.isPTT)
        case "poll":
            if let json = p.pollJSON,
               let data = json.data(using: .utf8),
               let poll = try? JSONDecoder().decode(BridgePoll.self, from: data) {
                body = .poll(question: poll.question,
                             options: poll.options,
                             selectableCount: poll.selectableCount)
            } else {
                body = .system(p.kind)
            }
        default:
            // F35: kind=="system" rows now carry a friendly text (e.g.
            // "Encryption key with X changed"). Use it when present;
            // fall back to the bare kind otherwise.
            if let t = p.text, !t.isEmpty {
                body = .system(t)
            } else {
                body = .system(p.kind)
            }
        }
        var m = UIMessage(
            id: p.id, chatJID: p.chatJID, senderJID: p.senderJID,
            fromMe: p.fromMe, timestamp: p.timestamp, body: body)
        m.editedAt = p.editedAt
        m.revokedAt = p.revokedAt
        m.revokedBy = p.revokedBy
        m.locallyDeleted = p.locallyDeleted
        m.starredAt = p.starredAt
        m.pinnedAt = p.pinnedAt
        m.isForwarded = p.isForwarded
        m.isViewOnce = p.isViewOnce
        m.viewOnceLocked = p.viewOnceLocked
        m.quotedMessageID = p.quotedMessageID
        m.quotedSenderJID = p.quotedSenderJID
        m.quotedFromMe = p.quotedFromMe
        m.quotedTextSnippet = p.quotedTextSnippet
        m.quotedKind = p.quotedKind
        m.mediaWidth = p.mediaWidth
        m.mediaHeight = p.mediaHeight

        // Insert sorted by timestamp.
        let idx = messages.firstIndex(where: { $0.timestamp > m.timestamp }) ?? messages.count
        messages.insert(m, at: idx)
        messageIDs.insert(m.id)
        invalidateTimeline()
        pendingScrollToID = id
    }

    /// F36: replace `messages` with a `jumpWindowSize`-row slice
    /// centered on the row whose id is `targetID`. Returns `true` on
    /// success, `false` if the persisted row can't be located. Used by
    /// `jumpToQuoted` to shrink the visible LazyVStack so
    /// `proxy.scrollTo` doesn't beachball.
    ///
    /// The three SwiftData fetches + UIMessage mapping run on a
    /// detached background `ModelContext` bound to the shared
    /// container; only the final `messages = …` commit hops back to
    /// MainActor. Keeps the jump from freezing the UI on large chats.
    private func rewindowAround(targetID: String) async -> Bool {
        guard let container = context?.container else { return false }
        let jid = chatJID
        let windowHalf = Self.jumpWindowSize / 2
        let uiMessages = await Task.detached(priority: .userInitiated) {
            () -> [UIMessage]? in
            let bgCtx = ModelContext(container)
            let targetDesc = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.id == targetID })
            guard let target = (try? bgCtx.fetch(targetDesc))?.first else {
                return nil
            }
            let targetTs = target.timestamp
            var beforeDesc = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate {
                    $0.chatJID == jid && $0.timestamp <= targetTs
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            beforeDesc.fetchLimit = windowHalf
            var afterDesc = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate {
                    $0.chatJID == jid && $0.timestamp > targetTs
                },
                sortBy: [SortDescriptor(\.timestamp, order: .forward)])
            afterDesc.fetchLimit = windowHalf
            let beforeRows = (try? bgCtx.fetch(beforeDesc)) ?? []
            let afterRows = (try? bgCtx.fetch(afterDesc)) ?? []
            let combined = beforeRows.reversed() + afterRows
            // Build the [UIMessage] array entirely on the bg context —
            // PersistedMessage instances must not cross actor
            // boundaries.
            return combined.map { Self.uiMessage(from: $0) }
        }.value
        guard let uiMessages else { return false }
        messages = uiMessages
        messageIDs = Set(uiMessages.map(\.id))
        invalidateTimeline()
        return true
    }

    /// F36: build a UIMessage from a PersistedMessage. Used by
    /// `rewindowAround`. Mirrors the body-construction logic in
    /// `buildHistorySnapshot` but factored into a shared helper so
    /// both paths stay in sync. `nonisolated` so the detached fetch
    /// task in `rewindowAround` can call it without hopping back to
    /// MainActor — it only reads PersistedMessage stored properties
    /// (which are safe on the bg ModelContext that fetched them) and
    /// constructs a value-type UIMessage.
    nonisolated private static func uiMessage(from p: PersistedMessage) -> UIMessage {
        let body: UIMessage.Body
        switch p.kind {
        case "text":
            body = .text(p.text ?? "")
        case "image", "video", "audio", "document", "sticker":
            body = .media(kind: p.kind, caption: p.mediaCaption,
                          fileName: p.mediaFileName, localPath: p.mediaPath,
                          waveform: p.audioWaveform, isPTT: p.isPTT)
        case "poll":
            if let json = p.pollJSON,
               let data = json.data(using: .utf8),
               let poll = try? JSONDecoder().decode(BridgePoll.self, from: data) {
                body = .poll(question: poll.question,
                             options: poll.options,
                             selectableCount: poll.selectableCount)
            } else {
                body = .system(p.kind)
            }
        default:
            if let t = p.text, !t.isEmpty {
                body = .system(t)
            } else {
                body = .system(p.kind)
            }
        }
        var m = UIMessage(
            id: p.id, chatJID: p.chatJID, senderJID: p.senderJID,
            fromMe: p.fromMe, timestamp: p.timestamp, body: body)
        m.editedAt = p.editedAt
        m.revokedAt = p.revokedAt
        m.revokedBy = p.revokedBy
        m.locallyDeleted = p.locallyDeleted
        m.starredAt = p.starredAt
        m.pinnedAt = p.pinnedAt
        m.isForwarded = p.isForwarded
        m.isViewOnce = p.isViewOnce
        m.viewOnceLocked = p.viewOnceLocked
        m.quotedMessageID = p.quotedMessageID
        m.quotedSenderJID = p.quotedSenderJID
        m.quotedFromMe = p.quotedFromMe
        m.quotedTextSnippet = p.quotedTextSnippet
        m.quotedKind = p.quotedKind
        m.mediaWidth = p.mediaWidth
        m.mediaHeight = p.mediaHeight
        return m
    }

    func didFinishScroll(to id: String) {
        highlightedID = id
        Task { [weak self] in
            // F36: bumped 1.2 s → 2.5 s so the user has time to spot
            // the highlight after the scroll-into-view animation
            // finishes (≈0.25 s) and the row settles. Previously the
            // highlight started fading before the user even noticed
            // anything happened.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self else { return }
            if self.highlightedID == id { self.highlightedID = nil }
        }
    }

    private static func quotedKind(of m: UIMessage) -> String {
        switch m.body {
        case .text:                       return "text"
        case .media(let kind, _, _, _, _, _):   return kind
        case .poll:                       return "poll"
        case .location(_, let isLive, _): return isLive ? "location_live" : "location"
        case .contact:                    return "contact"
        case .system:                     return "system"
        }
    }

    private static func quotedSnippet(of m: UIMessage) -> String {
        func trunc(_ s: String) -> String {
            s.count > 120 ? String(s.prefix(120)) + "…" : s
        }
        switch m.body {
        case .text(let t):
            return trunc(t)
        case .media(let kind, let caption, let fileName, _, _, _):
            if let c = caption, !c.isEmpty { return trunc(c) }
            if kind == "document", let n = fileName, !n.isEmpty { return trunc(n) }
            return "[\(kind)]"
        case .poll(let q, _, _):
            return trunc(q)
        case .location(let loc, let isLive, _):
            let label = isLive ? "Live location" : "Location"
            return loc.name.isEmpty ? label : trunc("\(label): \(loc.name)")
        case .contact(let c):
            return trunc("Contact: \(c.displayName)")
        case .system:
            return ""
        }
    }

    func startReply(to msg: UIMessage) {
        editTarget = nil
        replyTarget = msg
    }

    func startEdit(_ msg: UIMessage) {
        replyTarget = nil
        editTarget = msg
    }

    /// Pulls up the most recent own text message that's still within the
    /// edit window and starts editing it. Used by the arrow-up keyboard
    /// shortcut in the composer when the draft is empty. No-op when
    /// nothing eligible is found.
    func editLastOwnMessage() {
        guard let msg = messages.reversed().first(where: { m in
            MessageLifecycle.canEdit(m)
        }) else { return }
        startEdit(msg)
    }

    func cancelCompose() {
        replyTarget = nil
        editTarget = nil
    }

    /// Whether a message can be forwarded: text always; media only if we can
    /// rebuild it (a stored media ref) or it has a caption to forward as text;
    /// poll / system / revoked / locally-deleted never.
    func canForward(_ m: UIMessage) -> Bool {
        if m.revokedAt != nil || m.locallyDeleted { return false }
        switch m.body {
        case .text:
            return true
        case .media(_, let caption, _, _, _, _):
            if let c = caption, !c.isEmpty { return true }
            return mediaRefJSON(for: m.id) != nil
        case .poll, .location, .contact, .system:
            return false
        }
    }

    func beginForward(_ m: UIMessage) {
        forwardSelecting = true
        if canForward(m) { forwardSelection.insert(m.id) }
    }

    func toggleForward(_ id: String) {
        if forwardSelection.contains(id) {
            forwardSelection.remove(id)
        } else if let m = messages.first(where: { $0.id == id }), canForward(m) {
            forwardSelection.insert(id)
        }
    }

    func cancelForward() {
        forwardSelecting = false
        forwardSelection.removeAll()
    }

    /// Forward the selected messages to `chatJID` in chronological order.
    /// WhatsApp forwards carry no original author, so we embed the source
    /// sender's display name as a header line in the text / caption —
    /// otherwise a batch forwarded from several people is indistinguishable.
    /// `senderName` resolves a JID to a display name.
    func executeForward(to chatJID: String, senderName: (String) -> String) async {
        let ids = forwardSelection
        let ordered = messages.filter { ids.contains($0.id) }
        for m in ordered {
            let srcJID = m.fromMe ? client.ownJID : m.senderJID
            var author = senderName(srcJID)
            if author.isEmpty || author == srcJID {
                author = m.fromMe ? "You" : ""
            }
            let prefix = author.isEmpty ? "" : "\(author):\n"
            do {
                let result: BridgeSendResult
                var outKind = "text"
                var outText: String?
                var outCaption: String?
                var outFileName: String?
                var outRef: String?
                switch m.body {
                case .text(let t):
                    let body = prefix + t
                    result = try client.forwardText(chatJID, text: body,
                                                    ephemeralSeconds: dstEphemeralSec(chatJID))
                    outText = body
                case .media(let kind, let caption, let fileName, _, _, _):
                    if let ref = mediaRefJSON(for: m.id) {
                        let cap = prefix + (caption ?? "")
                        result = try client.forwardMedia(chatJID, refJSON: ref,
                                                          caption: cap, fileName: fileName ?? "",
                                                          ephemeralSeconds: dstEphemeralSec(chatJID))
                        outKind = kind
                        outCaption = cap.isEmpty ? nil : cap
                        outFileName = fileName
                        outRef = ref
                    } else if let c = caption, !c.isEmpty {
                        let body = prefix + c
                        result = try client.forwardText(chatJID, text: body,
                                                        ephemeralSeconds: dstEphemeralSec(chatJID))
                        outText = body
                    } else {
                        continue
                    }
                case .poll, .location, .contact, .system:
                    continue
                }
                persistForwarded(messageID: result.messageID, chatJID: chatJID,
                                 timestamp: result.timestamp, kind: outKind, text: outText,
                                 caption: outCaption, fileName: outFileName, refJSON: outRef)
                // Forwarding into the chat we're viewing: append optimistically
                // so it shows immediately (no echo updates our own sends).
                if chatJID == self.chatJID {
                    let body: UIMessage.Body = outKind == "text"
                        ? .text(outText ?? "")
                        : .media(kind: outKind, caption: outCaption,
                                 fileName: outFileName, localPath: nil)
                    var um = UIMessage(
                        id: result.messageID, chatJID: self.chatJID,
                        senderJID: client.ownJID, fromMe: true,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(result.timestamp)),
                        body: body)
                    um.isForwarded = true
                    if !messageIDs.contains(um.id) {
                        messages.append(um)
                        messageIDs.insert(um.id)
                        invalidateTimeline()
                    }
                }
            } catch {
                let sys = UIMessage(
                    id: UUID().uuidString, chatJID: self.chatJID, senderJID: "system",
                    fromMe: false, timestamp: .now,
                    body: .system("forward failed: \(error.localizedDescription)"))
                messages.append(sys)
                messageIDs.insert(sys.id)
                invalidateTimeline()
            }
        }
        // Refresh the destination's sidebar preview/timestamp from the
        // freshly-persisted forwarded rows (it's a different chat than the
        // one we're viewing, so no echo updates it otherwise).
        chatList?.refreshPreview(chatJID: chatJID)
        cancelForward()
    }

    /// Persist a forwarded outgoing message under the destination chat so it
    /// shows there (with the Forwarded tag) on switch / restart. Stores the
    /// exact text/caption we sent (incl. the author header).
    private func persistForwarded(messageID: String, chatJID: String, timestamp: Int64,
                                  kind: String, text: String?, caption: String?,
                                  fileName: String?, refJSON: String?) {
        guard let context else { return }
        let when = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let row = PersistedMessage(id: messageID, chatJID: chatJID,
                                   senderJID: client.ownJID, fromMe: true,
                                   timestamp: when, kind: kind, text: text,
                                   mediaCaption: caption, mediaFileName: fileName,
                                   mediaRefJSON: refJSON, isForwarded: true)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    /// Reads the persisted media ref JSON for a message id, if any.
    private func mediaRefJSON(for id: String) -> String? {
        guard let context else { return nil }
        let d = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d).first)?.mediaRefJSON
    }

    init(chatJID: String, client: WAClient, context: ModelContext? = nil) {
        self.chatJID = chatJID
        self.client = client
        self.context = context
    }

    deinit {
        // Cancel the coalescing flush task so it doesn't sleep 50ms holding
        // a stale [weak self] reference after the CVM is gone.
        pendingIngestFlush?.cancel()
    }

    /// Hard cap on initial load — large chats freeze SwiftUI's LazyVStack
    /// prefetcher if we hand it 10k+ rows at once. Newest N kept; older
    /// rows remain in storage and can be paged in later.
    /// First-paint cap. Lower than `extendedHistoryLimit` so chat-switch
    /// stays snappy; older rows page in via `loadMoreHistory` on scroll.
    static let historyLoadLimit = 60
    /// F36: bumped back to 10000 for the default chat-open load (user
    /// gets the whole persisted history at once), but `jumpToQuoted`
    /// re-windows to a 2500-row slice centered on the target before
    /// kicking the scroll — SwiftUI's ScrollViewReader.scrollTo on a
    /// 10k-row LazyVStack with variable-height rows beachballs the
    /// main thread because it has to lay out every preceding row to
    /// compute the target offset. The re-window keeps the jump
    /// instant; the user pages back to other windows via "Load
    /// earlier" if needed.
    static let extendedHistoryLimit = 10000
    /// F36: how many rows around the jump target to keep in the
    /// visible messages array. Empirically 2500 is the upper bound
    /// SwiftUI can scrollTo without a noticeable beachball.
    static let jumpWindowSize = 2500

    /// Message id to anchor the initial scroll position to. Set in
    /// `loadHistory` based on the chat's persisted unread count: anchors
    /// to the first unread message when there are unread messages,
    /// otherwise to the latest (bottom).
    private(set) var initialAnchorID: String?

    func loadHistory() {
        guard let container = context?.container else { return }
        let jid = chatJID
        // F31v2: always fetch up to `extendedHistoryLimit` on first
        // open. The original F9 historyLoadLimit=60 was sized for fast
        // chat-switch, but F2 made the snapshot build detached so
        // first-paint isn't on the critical path. With 10k cap and
        // LazyVStack, paying the SwiftData read up-front means the
        // whole persisted history is reachable without "Load earlier"
        // taps. Chats with fewer than the cap just return what they
        // have. Memory: ~1 KB per UIMessage × 10k = ~10 MB worst case.
        let limit = Self.extendedHistoryLimit
        let client = self.client
        // Closure captures the @MainActor-isolated WAClient instance.
        // `resolveLIDToPN` / `resolvePNToLID` are nonisolated, so the
        // canonicalize call is safe from any thread.
        let canonicalize: @Sendable (String) -> String = { jid in
            JIDNormalize.canonical(jid, client: client)
        }
        restoreDraftIfNeeded()
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = Self.buildHistorySnapshot(
                chatJID: jid,
                container: container,
                canonicalize: canonicalize,
                limit: limit)
            await self?.applyHistorySnapshot(snapshot)
        }
    }

    /// MainActor commit of a snapshot produced by
    /// `buildHistorySnapshot`. One assignment per published collection.
    ///
    /// Race guard: messages that arrived via `ingest()` / the event pump
    /// while the background snapshot was building (~100ms+ on large
    /// chats) get appended to `self.messages` first; an unconditional
    /// replace would wipe them. Preserve any rows whose id is not in
    /// the snapshot and append them in timestamp order — by definition
    /// they are newer than the snapshot's fetch time, so they sort
    /// after the snapshot's newest row.
    @MainActor
    private func applyHistorySnapshot(_ snap: ConversationHistorySnapshot) {
        // Warm the thumbnail cache for the visible bottom window BEFORE
        // assigning `self.messages` — once messages publish, the
        // LazyVStack starts laying out and the first body eval of each
        // image bubble runs `ThumbnailCache.shared.image(forPath:)`. If
        // the cache is cold that returns nil and the bubble paints a
        // placeholder; the async decode landings then flicker images in
        // one by one. The snapshot carries pre-decoded NSImages
        // (decode ran off-MainActor inside `buildHistorySnapshot`), so
        // preheat is a pointer-store loop on main — microseconds, not
        // the ~600-1200ms freeze the prior on-main decode caused (F10).
        // Placing this AFTER the assignment would defeat the point.
        ThumbnailCache.shared.preheat(snap.preheatThumbs)
        // Same contract for video bubbles: pre-decoded NSImages from
        // pre-existing SHA disk-cache PNGs land in the in-memory
        // cache BEFORE the LazyVStack lays out, so VideoThumbnailView's
        // first body eval hits the cache instead of returning nil →
        // gray placeholder → single-frame flicker (F11).
        ThumbnailCache.shared.preheatVideo(snap.preheatVideoThumbs)
        // Avatar preheat — the highest-impact one. Every message row
        // has an AvatarView; without this preheat the entire visible
        // window flashes initials placeholders for one frame before
        // the in-memory cache fills from disk. Decode ran off-MainActor
        // in the snapshot builder (F12).
        ThumbnailCache.shared.preheatAvatar(snap.preheatAvatars)
        // F58: ingest per-sender push-names from loaded history so
        // group senders resolve to a name instead of raw @lid prefix.
        if let session = chatList?.session {
            for (jid, name) in snap.pushNames {
                session.ingestPushName(jid: jid, name: name)
            }
        }
        let snapIDs = Set(snap.messages.map { $0.id })
        let lateArrivals = self.messages.filter { !snapIDs.contains($0.id) }
        if lateArrivals.isEmpty {
            self.messages = snap.messages
        } else {
            self.messages = snap.messages + lateArrivals.sorted { $0.timestamp < $1.timestamp }
        }
        // Rebuild the dedupe Set after the wholesale assignment.
        self.messageIDs = Set(self.messages.map(\.id))
        for (id, status) in snap.receiptStatus {
            self.receiptStatus[id] = status
        }
        for (id, byHash) in snap.reactionsBySender {
            self.reactionsBySender[id] = byHash
        }
        for (id, byHash) in snap.pollVotes {
            self.pollVotes[id] = byHash
        }
        for (id, path) in snap.localPaths {
            self.localPaths[id] = path
        }
        for (id, err) in snap.downloadErrors {
            self.downloadErrors[id] = err
        }
        self.initialAnchorID = snap.initialAnchorID
        for id in snap.unreadInboundIDs {
            self.unreadInboundIDs.insert(id)
        }
        // Kick downloads now that we're on MainActor (downloadTasks lives here).
        for target in snap.downloadTargets {
            if self.downloadTasks[target.id] != nil { continue }
            if self.localPaths[target.id] != nil { continue }
            ensureDownloadFromHistory(
                id: target.id, kind: target.kind, refJSON: target.refJSON)
        }
        // Whole-list replace + path / star hydration above invalidates
        // the sectioned-timeline cache exactly once for the apply pass.
        invalidateTimeline()
        // Auto-refetch expired (once per chat per session). The snapshot
        // carries only the candidate ids + timestamps; we look up the
        // anchor PersistedMessage on the main context for the existing
        // helper's signature.
        if !didAutoRefetchExpired,
           let oldest = snap.expiredOnLoad.min(by: { $0.timestamp < $1.timestamp }) {
            didAutoRefetchExpired = true
            let anchorID = oldest.id
            if let context,
               let row = try? context.fetch(
                FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.id == anchorID })).first {
                let ids = snap.expiredOnLoad.map { $0.id }
                autoRefetchExpiredBatch(anchor: row, allIDs: ids)
            }
        }
        let t = snap.timings
        // Logger with .public privacy renders the values in
        // Console.app — NSLog with format specifiers gets mangled
        // into <private> by the unified-log redaction.
        perfLog.log("loadHistory rows=\(t.rowCount, privacy: .public) scrub=\(t.scrubMs, format: .fixed(precision: 0), privacy: .public)ms fetch=\(t.fetchMs, format: .fixed(precision: 0), privacy: .public)ms map=\(t.mapMs, format: .fixed(precision: 0), privacy: .public)ms total=\(t.totalMs, format: .fixed(precision: 0), privacy: .public)ms")
    }

    /// Builds the chat-history snapshot off MainActor against a fresh
    /// background `ModelContext` bound to the shared container. All
    /// SwiftData reads, scrubs, sweeps, reaction + poll hydration, and
    /// per-row `fileExists` probes happen here; the produced value-type
    /// snapshot is then committed in one shot by
    /// `applyHistorySnapshot`.
    nonisolated static func buildHistorySnapshot(
        chatJID jid: String,
        container: ModelContainer,
        canonicalize: @Sendable (String) -> String,
        limit: Int
    ) -> ConversationHistorySnapshot {
        let context = ModelContext(container)
        let t0 = CFAbsoluteTimeGetCurrent()
        // One-shot migration: earlier builds persisted some rows with raw
        // (device-suffixed / @lid) chatJID via CVM.persist. Scrub anything
        // whose canonical form matches this chat back to canonical so the
        // primary fetch finds it. Gated per-chat via UserDefaults so we
        // pay the substring-scan cost only once per chat ever, not every
        // open. The whole-account scrub is a v0.6 era cleanup; new
        // installs and chats already scrubbed effectively bypass.
        let scrubKey = "yawac.cvm.scrubbedChat.\(jid)"
        if !UserDefaults.standard.bool(forKey: scrubKey),
           let at = jid.firstIndex(of: "@") {
            let userPart = String(jid[..<at])
            let scrubDescriptor = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.chatJID != jid && $0.chatJID.contains(userPart) })
            if let scrubRows = try? context.fetch(scrubDescriptor) {
                var changed = 0
                for r in scrubRows {
                    if canonicalize(r.chatJID) == jid {
                        r.chatJID = jid
                        changed += 1
                    }
                }
                if changed > 0 {
                    try? context.save()
                    NSLog("[yawac/cvm] migrated %d rows to canonical chatJID for %@",
                          changed, jid)
                }
            }
            UserDefaults.standard.set(true, forKey: scrubKey)
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let recentRows = (try? context.fetch(descriptor)) ?? []
        let t2 = CFAbsoluteTimeGetCurrent()
        let rows = recentRows.reversed().map { $0 }
        // Sweep legacy rows of non-displayable kinds. Gated per-chat
        // via UserDefaults — only the first open of each chat after
        // upgrading runs the loop + save. New chats never trip this.
        let sweepKey = "yawac.cvm.sweptChat.\(jid)"
        if !UserDefaults.standard.bool(forKey: sweepKey) {
            var swept = 0
            // F35: dropped "system" from the sweep list — we now emit
            // synthetic system rows (encryption-key-changed,
            // disappearing-timer-changed) that the user wants to see in
            // the chat. "reaction" + "protocol" still sweep because
            // those carry no human-visible body.
            for p in rows where p.kind == "reaction" || p.kind == "protocol" {
                context.delete(p)
                swept += 1
            }
            if swept > 0 { try? context.save() }
            UserDefaults.standard.set(true, forKey: sweepKey)
        }
        let displayable = rows.filter { p in
            p.kind != "reaction" && p.kind != "protocol" && p.kind != "system"
        }
        let messages: [UIMessage] = displayable.map { p in
            let body: UIMessage.Body
            switch p.kind {
            case "text":
                body = .text(p.text ?? "")
            case "image", "video", "audio", "document", "sticker":
                body = .media(kind: p.kind, caption: p.mediaCaption,
                              fileName: p.mediaFileName, localPath: p.mediaPath,
                              waveform: p.audioWaveform, isPTT: p.isPTT)
            case "poll":
                if let json = p.pollJSON,
                   let data = json.data(using: .utf8),
                   let poll = try? JSONDecoder().decode(BridgePoll.self, from: data) {
                    body = .poll(question: poll.question,
                                 options: poll.options,
                                 selectableCount: poll.selectableCount)
                } else {
                    body = .system(p.kind)
                }
            default:
                // F35: same fallback as in the buildHistorySnapshot
                // path above — surface the synthetic system text when
                // present.
                if let t = p.text, !t.isEmpty {
                    body = .system(t)
                } else {
                    body = .system(p.kind)
                }
            }
            var m = UIMessage(
                id: p.id,
                chatJID: p.chatJID,
                senderJID: p.senderJID,
                fromMe: p.fromMe,
                timestamp: p.timestamp,
                body: body)
            m.editedAt = p.editedAt
            m.revokedAt = p.revokedAt
            m.revokedBy = p.revokedBy
            m.locallyDeleted = p.locallyDeleted
            m.starredAt = p.starredAt
            m.pinnedAt = p.pinnedAt
            m.isForwarded = p.isForwarded
            m.isViewOnce = p.isViewOnce
            m.viewOnceLocked = p.viewOnceLocked
            m.quotedMessageID = p.quotedMessageID
            m.quotedSenderJID = p.quotedSenderJID
            m.quotedFromMe = p.quotedFromMe
            m.quotedTextSnippet = p.quotedTextSnippet
            m.quotedKind = p.quotedKind
            m.mediaWidth = p.mediaWidth
            m.mediaHeight = p.mediaHeight
            return m
        }
        // Hydrate persisted delivery status (fromMe only — receipts for
        // inbound messages aren't shown).
        var receiptStatus: [String: UIMessage.Status] = [:]
        for p in displayable where p.fromMe {
            switch p.deliveryStatus {
            case "delivered": receiptStatus[p.id] = .delivered
            case "played":    receiptStatus[p.id] = .played
            case "read":      receiptStatus[p.id] = .read
            default:          receiptStatus[p.id] = .sent
            }
        }

        // F58: extract per-sender push-names so group senders resolve
        // their display names instead of falling through to raw JID
        // prefixes. Real-time messages already ingest push-names via
        // ContentView's event stream, but historical loads (full-history
        // sync, app restart) skip that path; the contactNames dict
        // never got populated for senders the user hasn't saved.
        var pushNames: [String: String] = [:]
        for p in displayable where !p.fromMe {
            if let push = p.senderPushName, !push.isEmpty {
                pushNames[p.senderJID] = push
            }
        }

        // Hydrate reactions for the loaded messages from PersistedReaction.
        let ids = Set(displayable.map { $0.id })
        let rxDescriptor = FetchDescriptor<PersistedReaction>(
            predicate: #Predicate { ids.contains($0.targetMessageID) })
        var reactionsBySender: [String: [String: String]] = [:]
        if let rxRows = try? context.fetch(rxDescriptor) {
            for r in rxRows {
                var byHash = reactionsBySender[r.targetMessageID] ?? [:]
                byHash[r.senderJID] = r.emoji
                reactionsBySender[r.targetMessageID] = byHash
            }
        }

        // Hydrate poll vote tallies. Only seed entries for polls in the
        // current window — older polls re-hydrate when scrolled back in.
        var pollVotes: [String: [String: Set<String>]] = [:]
        let pollIDs = Set(displayable.filter { $0.kind == "poll" }.map { $0.id })
        if !pollIDs.isEmpty {
            let pvDescriptor = FetchDescriptor<PersistedPollVote>(
                predicate: #Predicate { pollIDs.contains($0.pollMessageID) })
            if let pvRows = try? context.fetch(pvDescriptor) {
                for v in pvRows {
                    guard let data = v.optionHashesJSON.data(using: .utf8),
                          let hashes = try? JSONDecoder().decode([String].self, from: data)
                    else { continue }
                    var byHash = pollVotes[v.pollMessageID] ?? [:]
                    for h in hashes {
                        var set = byHash[h] ?? []
                        set.insert(v.voterJID)
                        byHash[h] = set
                    }
                    pollVotes[v.pollMessageID] = byHash
                }
            }
        }

        // Seed localPaths from any persisted media files; collect rows
        // that need a download Task kicked once on MainActor. We don't
        // touch `downloadTasks` here — it's MainActor-only — so the
        // apply step re-checks before scheduling.
        var localPaths: [String: String] = [:]
        var downloadErrors: [String: String] = [:]
        var downloadTargets: [ConversationHistorySnapshot.DownloadTarget] = []
        var expiredOnLoad: [ConversationHistorySnapshot.ExpiredEntry] = []
        let downloadable: Set<String> = ["image", "sticker", "video", "audio", "document"]
        for p in rows {
            if let path = p.mediaPath, FileManager.default.fileExists(atPath: path) {
                localPaths[p.id] = path
                continue
            }
            guard downloadable.contains(p.kind) else { continue }

            // Fast path: probe the deterministic cache path before
            // queueing a Task. Most chats reopen with everything
            // already cached — avoids spawning hundreds of no-op
            // download tasks that flood the actor.
            if let cached = Self.cachedFilePath(
                id: p.id, kind: p.kind, mediaFileName: p.mediaFileName) {
                localPaths[p.id] = cached
                continue
            }
            if p.mediaExpired {
                // Server has aged this media out — bytes are gone.
                // Skip re-attempts on every chat reload.
                downloadErrors[p.id] = "media expired"
                expiredOnLoad.append(.init(id: p.id, timestamp: p.timestamp))
                continue
            }

            guard let refJSON = p.mediaRefJSON else {
                // Persisted before mediaRefJSON column existed — no way to
                // fetch. Surface so user isn't stuck on infinite spinner.
                downloadErrors[p.id] = "no download info (re-pair to refresh)"
                continue
            }
            downloadTargets.append(
                .init(id: p.id, kind: p.kind, refJSON: refJSON))
        }

        // Pick initial scroll anchor: if there are unread inbound
        // messages, jump to the first one (so the user starts reading
        // where they left off). Otherwise stick to the latest.
        let pcDescriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        let unread = (try? context.fetch(pcDescriptor))?.first?.unread ?? 0
        var initialAnchorID: String?
        var unreadInboundIDs: Set<String> = []
        // F31: when unread exceeds what we loaded, anchor to the
        // OLDEST loaded message so the user lands on the deepest
        // unread we have instead of snapping to the bottom (which
        // hid the entire offline backlog). "Load earlier messages"
        // then digs further. Loading limit is already scaled by
        // unread in `loadHistory`, capped at extendedHistoryLimit.
        if unread > 0 && !messages.isEmpty {
            if unread <= messages.count {
                let firstUnreadIdx = messages.count - unread
                initialAnchorID = messages[firstUnreadIdx].id
            } else {
                initialAnchorID = messages.first?.id
            }
        } else {
            initialAnchorID = messages.last?.id
        }
        // Seed the dwell-tracked unread set. We don't know exactly
        // which message ids were unread on the phone, so we take
        // the trailing `unread` inbound rows as the best guess —
        // matches the first-unread scroll anchor above. When unread
        // exceeds loaded messages, mark every loaded inbound as
        // unread (we can't be more precise without older anchors).
        if unread > 0 {
            let inbound = messages.filter { !$0.fromMe }
            let take = min(unread, inbound.count)
            for m in inbound.suffix(take) {
                unreadInboundIDs.insert(m.id)
            }
        }
        // Preheat the in-memory thumbnail cache for the visible bottom
        // window: the last ~30 image/sticker rows with on-disk media.
        // Read raw file bytes AND run the ImageIO downsample here
        // (off MainActor — `buildHistorySnapshot` is called from a
        // `Task.detached` in `loadHistory`). The pre-decoded NSImage
        // is then handed to MainActor's `applyHistorySnapshot` for a
        // pointer-store into `ThumbnailCache` — no decode on main.
        // Prior version carried raw `Data` and decoded inside
        // `applyHistorySnapshot`, which paid 600-1200ms of MainActor
        // CGImageSourceCreateThumbnailAtIndex per chat switch (F10).
        // Caps: 30 files, 5 MB per file — bounds memory for
        // pathological attachments.
        var preheatThumbs: [String: PreheatImage] = [:]
        let preheatMaxCount = 30
        let preheatPerFileCap = 5 * 1024 * 1024
        var preheatRemaining = preheatMaxCount
        // Iterate the persisted rows back-to-front: `displayable` is
        // sorted oldest-first (mirrors `messages`), so the trailing
        // entries are what `.defaultScrollAnchor(.bottom)` paints first.
        for p in displayable.reversed() {
            if preheatRemaining == 0 { break }
            guard p.kind == "image" || p.kind == "sticker" else { continue }
            guard let path = localPaths[p.id] else { continue }
            let url = URL(fileURLWithPath: path)
            // Skip oversize files: per-file cap protects against a
            // forgotten 40 MB sticker pack dumping into RAM.
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size > preheatPerFileCap { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.count > preheatPerFileCap { continue }
            guard let img = ThumbnailCache.decode(
                data: data, maxPixel: ThumbnailCache.imageBubbleMaxPixelExternal)
            else { continue }
            preheatThumbs[path] = PreheatImage(img)
            preheatRemaining -= 1
        }
        // Same preheat treatment for video bubbles: walk the last ~30
        // video rows with on-disk media, look up the SHA disk-cache
        // PNG path, read its bytes if present, decode off-MainActor.
        // Skip rows whose PNG hasn't been generated yet — the cache's
        // async miss path will fall through to AVAsset generation on
        // first paint. Caps mirror the image branch: 30 entries, 5 MB
        // per file. Keyed by the SOURCE video file path (NOT the SHA
        // PNG path), since that's what VideoThumbnailView passes to
        // `videoImage(forPath:)` at body time. The values are
        // pre-decoded NSImages (F11).
        var preheatVideoThumbs: [String: PreheatImage] = [:]
        var preheatVideoRemaining = preheatMaxCount
        for p in displayable.reversed() {
            if preheatVideoRemaining == 0 { break }
            guard p.kind == "video" else { continue }
            guard let sourcePath = localPaths[p.id] else { continue }
            let pngURL = VideoThumbnailView.cachePath(for: sourcePath)
            guard FileManager.default.fileExists(atPath: pngURL.path) else { continue }
            if let size = (try? pngURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size > preheatPerFileCap { continue }
            guard let data = try? Data(contentsOf: pngURL) else { continue }
            if data.count > preheatPerFileCap { continue }
            guard let img = ThumbnailCache.decode(
                data: data, maxPixel: ThumbnailCache.videoThumbMaxPixelExternal)
            else { continue }
            preheatVideoThumbs[sourcePath] = PreheatImage(img)
            preheatVideoRemaining -= 1
        }
        // Avatar preheat: collect distinct sender canonical-JID cache
        // keys from the last ~60 visible messages, read their on-disk
        // avatar bytes, decode off-MainActor. Highest-impact preheat
        // since EVERY message row has an AvatarView (F12). Caps
        // mirror the image preheat — 60 entries, 5 MB per file —
        // since most avatars are well under 100 KB anyway.
        var preheatAvatars: [String: PreheatImage] = [:]
        let avatarPreheatMaxCount = 60
        var avatarPreheatRemaining = avatarPreheatMaxCount
        var seenAvatarKeys: Set<String> = []
        for m in messages.reversed() {
            if avatarPreheatRemaining == 0 { break }
            let key = canonicalize(m.senderJID)
            if !seenAvatarKeys.insert(key).inserted { continue }
            guard let url = AvatarCache.cachedURL(for: key),
                  FileManager.default.fileExists(atPath: url.path)
            else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size > preheatPerFileCap { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.count > preheatPerFileCap { continue }
            guard let img = ThumbnailCache.decode(
                data: data, maxPixel: ThumbnailCache.avatarMaxPixelExternal)
            else { continue }
            preheatAvatars[key] = PreheatImage(img)
            avatarPreheatRemaining -= 1
        }
        let t3 = CFAbsoluteTimeGetCurrent()
        return ConversationHistorySnapshot(
            messages: messages,
            receiptStatus: receiptStatus,
            reactionsBySender: reactionsBySender,
            pollVotes: pollVotes,
            localPaths: localPaths,
            preheatThumbs: preheatThumbs,
            preheatVideoThumbs: preheatVideoThumbs,
            preheatAvatars: preheatAvatars,
            initialAnchorID: initialAnchorID,
            unreadInboundIDs: unreadInboundIDs,
            downloadTargets: downloadTargets,
            downloadErrors: downloadErrors,
            expiredOnLoad: expiredOnLoad,
            pushNames: pushNames,
            timings: .init(
                scrubMs: (t1 - t0) * 1000,
                fetchMs: (t2 - t1) * 1000,
                mapMs: (t3 - t2) * 1000,
                totalMs: (t3 - t0) * 1000,
                rowCount: messages.count))
    }

    /// Builds the paged-older snapshot off MainActor — like
    /// `buildHistorySnapshot` but without reaction / poll-vote
    /// hydration (those are already live on the main thread) and
    /// without the scrub / sweep migrations (those ran on first open).
    nonisolated static func buildEarlierSnapshot(
        chatJID jid: String,
        container: ModelContainer,
        limit: Int
    ) -> ConversationEarlierSnapshot {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        guard let recentRows = try? context.fetch(descriptor) else {
            return .init(messages: [])
        }
        let rows = recentRows.reversed().map { $0 }
        let displayable = rows.filter { p in
            p.kind != "reaction" && p.kind != "protocol" && p.kind != "system"
        }
        let messages: [UIMessage] = displayable.map { p in
            let body: UIMessage.Body
            switch p.kind {
            case "text":
                body = .text(p.text ?? "")
            case "image", "video", "audio", "document", "sticker":
                body = .media(kind: p.kind, caption: p.mediaCaption,
                              fileName: p.mediaFileName, localPath: p.mediaPath,
                              waveform: p.audioWaveform, isPTT: p.isPTT)
            case "poll":
                if let json = p.pollJSON,
                   let data = json.data(using: .utf8),
                   let poll = try? JSONDecoder().decode(BridgePoll.self, from: data) {
                    body = .poll(question: poll.question,
                                 options: poll.options,
                                 selectableCount: poll.selectableCount)
                } else {
                    body = .system(p.kind)
                }
            default:
                // F35: same fallback as the other two snapshot sites —
                // surface the synthetic system text when present.
                if let t = p.text, !t.isEmpty {
                    body = .system(t)
                } else {
                    body = .system(p.kind)
                }
            }
            return UIMessage(
                id: p.id, chatJID: p.chatJID, senderJID: p.senderJID,
                fromMe: p.fromMe, timestamp: p.timestamp, body: body)
        }
        return .init(messages: messages)
    }

    /// Probes the deterministic MediaCache path for a row without
    /// touching MainActor state — used by the snapshot builder to skip
    /// download Task spawning when the file is already on disk.
    nonisolated static func cachedFilePath(
        id: String, kind: String, mediaFileName: String?
    ) -> String? {
        let fm = FileManager.default
        let base: URL
        do {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            base = caches.appendingPathComponent("yawac-media", isDirectory: true)
        } catch { return nil }
        var candidates: [String] = []
        if kind == "document", let fn = mediaFileName {
            let e = (fn as NSString).pathExtension.lowercased()
            if !e.isEmpty { candidates.append(e) }
        }
        switch kind {
        case "image":    candidates.append(contentsOf: ["jpg", "png", "webp", "gif"])
        case "video":    candidates.append(contentsOf: ["mp4", "mov", "webm"])
        case "audio":    candidates.append(contentsOf: ["ogg", "mp3", "m4a", "opus", "wav"])
        case "sticker":  candidates.append("webp")
        case "document": candidates.append(contentsOf: ["pdf", "bin"])
        default:         candidates.append("bin")
        }
        for ext in candidates {
            let path = base.appendingPathComponent("\(id).\(ext)").path
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Re-requests the recent slice of this chat from the primary phone so
    /// the response's WebMessageInfo.pollUpdates field carries the current
    /// vote tallies. Used for polls created during this companion's
    /// connected window — those polls had empty pollUpdates when first
    /// observed (no votes yet), and live PollUpdate events for them are
    /// only delivered if the voter happens to fan votes to this device.
    /// On-demand HistorySync requested at the chat's newest message gives
    /// the phone a chance to bundle all current votes into the response.
    func refreshPollTallies() {
        guard !refreshingPolls, let container = context?.container else { return }
        refreshingPolls = true
        let jid = chatJID
        Task { @MainActor [weak self] in
            // Anchor at the newest message in the chat — server returns up to
            // ~50 messages older than the anchor, which includes recent polls.
            // Fetch on a detached bg ModelContext so the main thread stays
            // free while SQLite resolves the index lookup.
            let anchor = await Task.detached(priority: .userInitiated) {
                () -> (id: String, senderJID: String, fromMe: Bool, ts: Int64)? in
                let bgCtx = ModelContext(container)
                var descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.chatJID == jid },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
                descriptor.fetchLimit = 1
                guard let row = (try? bgCtx.fetch(descriptor))?.first else {
                    return nil
                }
                return (row.id, row.senderJID, row.fromMe,
                        Int64(row.timestamp.timeIntervalSince1970))
            }.value
            guard let self else { return }
            guard let anchor else {
                self.refreshingPolls = false
                return
            }
            defer { self.refreshingPolls = false }
            try? self.client.requestOlderHistory(
                chatJID: self.chatJID,
                oldestMsgID: anchor.id,
                oldestSenderJID: anchor.senderJID,
                oldestFromMe: anchor.fromMe,
                oldestTimestampSec: anchor.ts,
                count: 50)
            // PollVote events from the response stream into pollVotes via
            // ConversationView's .pollVote subscriber — no further work
            // here. Give the response a few seconds to arrive before
            // clearing the spinner.
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Asks the phone for ~50 messages older than the oldest one we currently
    /// have loaded for this chat. The phone's reply arrives as a normal
    /// HistorySync event; messages persist via the existing ChatList path,
    /// then we re-query PersistedMessage with a bigger window.
    func requestOlderHistory() {
        guard !loadingOlder, !olderUnavailable,
              let container = context?.container else { return }
        loadingOlder = true
        let jid = chatJID
        Task { @MainActor [weak self] in
            // Find oldest persisted message for this chat (not just
            // in-memory, since the in-memory cap is 500). Fetch on a
            // detached bg ModelContext so the main thread isn't blocked
            // while SQLite resolves the chatJID/timestamp index.
            let anchor = await Task.detached(priority: .userInitiated) {
                () -> (id: String, senderJID: String, fromMe: Bool, ts: Int64)? in
                let bgCtx = ModelContext(container)
                var descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.chatJID == jid },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)])
                descriptor.fetchLimit = 1
                guard let row = (try? bgCtx.fetch(descriptor))?.first else {
                    return nil
                }
                return (row.id, row.senderJID, row.fromMe,
                        Int64(row.timestamp.timeIntervalSince1970))
            }.value
            guard let self else { return }
            guard let anchor else {
                self.loadingOlder = false
                return
            }
            defer { self.loadingOlder = false }
            do {
                try self.client.requestOlderHistory(
                    chatJID: self.chatJID,
                    oldestMsgID: anchor.id,
                    oldestSenderJID: anchor.senderJID,
                    oldestFromMe: anchor.fromMe,
                    oldestTimestampSec: anchor.ts,
                    count: 50)
                // After ~5 s, if no new rows landed, mark unavailable so the
                // user isn't given an indefinite "Loading…" UI.
                try? await Task.sleep(for: .seconds(5))
                let beforeCount = self.messages.count
                await self.loadEarlier(by: 200)
                if self.messages.count == beforeCount {
                    self.olderUnavailable = true
                }
            } catch {
                let sys = UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("history request failed: \(error.localizedDescription)"))
                self.messages.insert(sys, at: 0)
                self.messageIDs.insert(sys.id)
                self.invalidateTimeline()
            }
        }
    }

    /// Re-runs the loadHistory query but with a larger fetchLimit so newly-
    /// arrived older rows become visible. SwiftData fetch + mapping run
    /// off MainActor; the assignment is committed back on MainActor.
    ///
    /// Race guard: the earlier-snapshot is a superset of the current
    /// window (larger fetchLimit, same chat), so ids in `self.messages`
    /// should be present. A brand-new message arriving between fetch
    /// and apply would not be in the snapshot — preserve those rows so
    /// they aren't wiped.
    private func loadEarlier(by additional: Int) async {
        let newLimit = max(messages.count + additional, Self.historyLoadLimit)
        let jid = chatJID
        guard let container = context?.container else { return }
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.buildEarlierSnapshot(
                chatJID: jid, container: container, limit: newLimit)
        }.value
        let snapIDs = Set(snapshot.messages.map { $0.id })
        let lateArrivals = self.messages.filter { !snapIDs.contains($0.id) }
        if lateArrivals.isEmpty {
            self.messages = snapshot.messages
        } else {
            self.messages = snapshot.messages + lateArrivals.sorted { $0.timestamp < $1.timestamp }
        }
        // Rebuild the dedupe Set after the wholesale assignment.
        self.messageIDs = Set(self.messages.map(\.id))
        invalidateTimeline()
    }

    func retryDownload(messageID: String, kind: String, refJSON: String) {
        downloadErrors[messageID] = nil
        downloadTasks[messageID]?.cancel()
        downloadTasks[messageID] = nil
        // User-tap retry clears the once-per-session MediaRetry guard so the
        // phone can be re-asked. Also unlatch the persisted media-expired
        // flag — the user explicitly asked us to try again, and if we
        // first backfill via history-sync the primary device may have
        // returned fresh keys.
        retriesRequested.remove(messageID)
        clearMediaExpiredFlag(messageID)
        ensureDownloadFromHistory(id: messageID, kind: kind, refJSON: refJSON)
    }

    /// Triggered when the user hits the retry affordance on a bubble we
    /// previously marked `mediaExpired`. Issues an on-demand history-sync
    /// request anchored at the failing message's timestamp so the
    /// primary device gets a chance to re-upload the bytes with a fresh
    /// MediaKey. After ~10s we re-attempt the download.
    func refetchExpiredMedia(messageID: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == messageID })
        guard let row = try? context.fetch(descriptor).first else { return }
        let kind = row.kind
        clearMediaExpiredFlag(messageID)
        downloadErrors[messageID] = "asking phone to re-upload…"
        let chat = chatJID
        let senderJID = row.senderJID
        let fromMe = row.fromMe
        let ts = Int64(row.timestamp.timeIntervalSince1970)
        let client = self.client
        Task { [weak self] in
            do {
                try client.requestOlderHistory(
                    chatJID: chat,
                    oldestMsgID: messageID,
                    oldestSenderJID: senderJID,
                    oldestFromMe: fromMe,
                    oldestTimestampSec: ts,
                    count: 50)
            } catch {
                await MainActor.run {
                    self?.downloadErrors[messageID] = "backfill failed: \(error.localizedDescription)"
                }
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard let self else { return }
                // Re-read row in case applyHistorySync persisted a fresher
                // refJSON in the meantime.
                let d = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == messageID })
                if let fresh = try? self.context?.fetch(d).first,
                   let ref = fresh.mediaRefJSON {
                    self.retriesRequested.remove(messageID)
                    self.ensureDownloadFromHistory(id: messageID, kind: kind, refJSON: ref)
                }
            }
        }
    }

    /// Fires once per chat session when at least one media row is
    /// already flagged `mediaExpired`. Issues a single backfill
    /// request anchored at the oldest expired message — the primary
    /// device's response covers ~50 messages around that timestamp,
    /// so we typically refresh refs for many expired media in one
    /// shot. After waiting for the HistorySync to land we clear the
    /// expired flag on each candidate and re-attempt the download.
    private func autoRefetchExpiredBatch(anchor: PersistedMessage, allIDs: [String]) {
        let chat = chatJID
        let senderJID = anchor.senderJID
        let fromMe = anchor.fromMe
        let anchorID = anchor.id
        let ts = Int64(anchor.timestamp.timeIntervalSince1970)
        let client = self.client
        Task { [weak self] in
            do {
                try client.requestOlderHistory(
                    chatJID: chat,
                    oldestMsgID: anchorID,
                    oldestSenderJID: senderJID,
                    oldestFromMe: fromMe,
                    oldestTimestampSec: ts,
                    count: 50)
            } catch {
                // Best-effort; don't surface — manual Refetch stays available.
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard let self else { return }
                for id in allIDs {
                    self.clearMediaExpiredFlag(id)
                    self.retriesRequested.remove(id)
                    let d = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
                    if let row = try? self.context?.fetch(d).first,
                       let ref = row.mediaRefJSON {
                        self.downloadErrors[id] = nil
                        self.ensureDownloadFromHistory(id: id, kind: row.kind, refJSON: ref)
                    }
                }
            }
        }
    }

    private func clearMediaExpiredFlag(_ id: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        if let row = try? context.fetch(descriptor).first, row.mediaExpired {
            row.mediaExpired = false
            try? context.save()
        }
    }

    func retryHandler(for message: UIMessage) -> (() -> Void)? {
        guard case .media(let kind, _, _, _, _, _) = message.body else { return nil }
        guard let context else { return nil }
        let id = message.id
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id })
        guard let row = try? context.fetch(descriptor).first else { return nil }
        // When the row is already marked expired, retry chains through the
        // history-sync re-upload request first. Otherwise hit the normal
        // download path directly.
        if row.mediaExpired {
            return { [weak self] in
                self?.refetchExpiredMedia(messageID: id)
            }
        }
        guard let refJSON = row.mediaRefJSON else { return nil }
        return { [weak self] in
            self?.retryDownload(messageID: id, kind: kind, refJSON: refJSON)
        }
    }

    private func ensureDownload(for message: BridgeMessage) {
        guard let media = message.media, let ref = media.ref else { return }
        let kind = message.kind
        let allowedKinds: Set<String> = ["image", "sticker", "video", "audio", "document"]
        guard allowedKinds.contains(kind),
              localPaths[message.id] == nil,
              downloadTasks[message.id] == nil else { return }

        // Size cap: 100 MB. Larger files surface as an error with a Retry
        // button that bypasses the cap (user opt-in).
        let maxBytes: Int64 = 100 * 1024 * 1024
        if let size = media.sizeBytes, size > 0, size > maxBytes {
            let mb = Double(size) / (1024.0 * 1024.0)
            downloadErrors[message.id] = String(format: "Too large (%.1f MB)", mb)
            return
        }

        guard let refJSON = ref.json else { return }
        ensureDownloadFromHistory(id: message.id, kind: kind, refJSON: refJSON)
    }

    /// Picks a sensible on-disk extension so macOS opens the file with the
    /// correct app. Documents use the original filename's extension when
    /// available, falling back to a mime-derived one or `.bin`.
    private func extensionFor(kind: String, refJSON: String, messageID: String) -> String {
        switch kind {
        case "image":   return mimeExt(refJSON: refJSON, fallback: "jpg", prefix: "image/")
        case "video":   return mimeExt(refJSON: refJSON, fallback: "mp4", prefix: "video/")
        case "audio":   return mimeExt(refJSON: refJSON, fallback: "ogg", prefix: "audio/")
        case "sticker": return "webp"
        case "document":
            if let context, let row = try? context.fetch(
                FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == messageID })
            ).first {
                if let fn = row.mediaFileName, !fn.isEmpty {
                    let e = (fn as NSString).pathExtension
                    if !e.isEmpty { return e.lowercased() }
                }
            }
            return mimeExt(refJSON: refJSON, fallback: "bin", prefix: "")
        default:
            return "bin"
        }
    }

    private func mimeExt(refJSON: String, fallback: String, prefix: String) -> String {
        guard let data = refJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let mime = dict["mimetype"] as? String,
              !mime.isEmpty else { return fallback }
        switch mime.lowercased() {
        case "image/jpeg":  return "jpg"
        case "image/png":   return "png"
        case "image/gif":   return "gif"
        case "image/webp":  return "webp"
        case "video/mp4":   return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm":  return "webm"
        case "audio/mpeg":  return "mp3"
        case "audio/ogg":   return "ogg"
        case "audio/mp4":   return "m4a"
        case "audio/wav":   return "wav"
        case "audio/ogg; codecs=opus": return "opus"
        case "application/pdf":  return "pdf"
        case "application/zip":  return "zip"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "text/plain":  return "txt"
        default:
            // Use the subtype as a last resort (e.g. "application/foo" → "foo").
            if let slash = mime.firstIndex(of: "/") {
                let sub = mime[mime.index(after: slash)...]
                let cleaned = sub.split(separator: ";").first.map(String.init) ?? String(sub)
                if !cleaned.isEmpty { return cleaned }
            }
            return fallback
        }
    }

    private func ensureDownloadFromHistory(id: String, kind: String, refJSON: String) {
        let ext = extensionFor(kind: kind, refJSON: refJSON, messageID: id)
        let client = self.client
        downloadTasks[id] = Task { @MainActor [weak self] in
            let result = await MediaCache.shared.ensure(
                messageID: id, ext: ext, refJSON: refJSON, using: client)
            if let self {
                switch result {
                case .file(let url):
                    self.localPaths[id] = url.path
                    self.invalidateTimeline()
                    self.downloadErrors[id] = nil
                case .failed(let reason):
                    self.downloadErrors[id] = reason
                    // First failure → ask phone to re-upload. Second
                    // failure (i.e. we already requested retry once and
                    // it still mismatches) → the bytes are gone for good
                    // on the server side. Mark expired so we stop trying.
                    if self.retriesRequested.contains(id),
                       self.looksLikeExpiredError(reason) {
                        self.markMediaExpired(id, reason: reason)
                    } else {
                        self.tryRequestMediaRetry(messageID: id, reason: reason)
                    }
                case .missingRef:
                    self.downloadErrors[id] = "no ref"
                }
            }
            self?.downloadTasks[id] = nil
        }
    }

    private func looksLikeExpiredError(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("plaintext sha mismatch")
            || r.contains("hash of media ciphertext")
            || r.contains("status code 410")
            || r.contains("status code 404")
            // Retry-path failures: phone responded but our MediaKey can't
            // decrypt the notification, or phone said no.
            || r.contains("failed to decrypt notification")
            || r.contains("message authentication failed")
            || r.contains("phone retry returned no path")
    }

    private func markMediaExpired(_ id: String, reason: String) {
        downloadErrors[id] = "media expired"
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        if let row = try? context.fetch(descriptor).first {
            row.mediaExpired = true
            try? context.save()
        }
    }

    private func tryRequestMediaRetry(messageID: String, reason: String) {
        guard !retriesRequested.contains(messageID) else { return }
        let lower = reason.lowercased()
        let triggers = ["403", "404", "410",
                        "hash of media ciphertext",
                        "plaintext sha mismatch",
                        "sha mismatch"]
        guard triggers.contains(where: { lower.contains($0) }) else { return }
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == messageID })
        guard let row = try? context.fetch(descriptor).first,
              let refJSON = row.mediaRefJSON else { return }
        retriesRequested.insert(messageID)
        do {
            try client.requestMediaRetry(
                chatJID: row.chatJID,
                senderJID: row.fromMe ? row.chatJID : row.senderJID,
                msgID: messageID,
                fromMe: row.fromMe,
                refJSON: refJSON)
            downloadErrors[messageID] = "asking phone to re-upload…"
        } catch {
            downloadErrors[messageID] = "retry request failed: \(error.localizedDescription)"
        }
    }

    func applyMediaRetry(messageID: String, ok: Bool, newDirectPath: String?, error: String?) {
        guard let container = context?.container else { return }
        if !ok {
            let reason = "phone retry failed: \(error ?? "?")"
            if looksLikeExpiredError(reason) {
                markMediaExpired(messageID, reason: reason)
            } else {
                downloadErrors[messageID] = reason
            }
            return
        }
        guard let newPath = newDirectPath, !newPath.isEmpty else {
            downloadErrors[messageID] = "phone retry returned no path"
            return
        }
        // F22: move the SwiftData fetch + JSON patch + save off MainActor.
        // Background context with the same ModelContainer is per-thread
        // safe and matches the F2 / F3 pattern. MainActor only handles
        // the VM state update (downloadErrors / downloadTasks /
        // ensureDownloadFromHistory) after the persistence is committed.
        Task.detached(priority: .userInitiated) { [weak self] in
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.id == messageID })
            guard let row = try? ctx.fetch(descriptor).first,
                  let oldRefJSON = row.mediaRefJSON
            else { return }
            // Patch direct_path inside the stored MediaRef JSON so future
            // retries (and the immediate re-download below) use the fresh
            // path.
            var refDict = (try? JSONSerialization.jsonObject(with: Data(oldRefJSON.utf8))) as? [String: Any] ?? [:]
            refDict["direct_path"] = newPath
            guard let newJSON = try? JSONSerialization.data(withJSONObject: refDict),
                  let s = String(data: newJSON, encoding: .utf8)
            else { return }
            row.mediaRefJSON = s
            try? ctx.save()
            let kind = row.kind
            await self?.applyMediaRetrySucceeded(
                messageID: messageID, kind: kind, refJSON: s)
        }
    }

    @MainActor
    private func applyMediaRetrySucceeded(messageID: String,
                                          kind: String,
                                          refJSON: String) {
        downloadErrors[messageID] = nil
        downloadTasks[messageID]?.cancel()
        downloadTasks[messageID] = nil
        ensureDownloadFromHistory(id: messageID, kind: kind, refJSON: refJSON)
    }

    func sendDraft() async {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        draft = ""

        let mentionsSnapshot = activeMentions
        activeMentions = []

        let allP = (groupParticipants ?? []).map(\.jid)
        let (body, mentionedJIDs) = Self.encodeMentions(
            body: raw, mentions: mentionsSnapshot, allParticipants: allP)

        let replyTo = replyTarget
        replyTarget = nil

        // F51: optimistic send. Paint the outgoing bubble immediately with
        // a temporary local ID; dispatch the CGo bridge call off MainActor;
        // when it returns, REPLACE the temp row with one keyed by the real
        // bridge-assigned messageID so future receipts route correctly.
        // The previous path ran the synchronous bridge call inline on
        // MainActor, which blocked the runloop ~50-200ms — the composer
        // text stayed visible (still selected) until the bridge returned,
        // then the bubble suddenly appeared.
        let tempID = "local:" + UUID().uuidString
        var optimistic = UIMessage(
            id: tempID,
            chatJID: chatJID,
            senderJID: "me",
            fromMe: true,
            timestamp: .now,
            body: .text(body))
        if let q = replyTo {
            optimistic.quotedMessageID = q.id
            optimistic.quotedSenderJID = q.senderJID
            optimistic.quotedFromMe = q.fromMe
            optimistic.quotedKind = Self.quotedKind(of: q)
            optimistic.quotedTextSnippet = Self.quotedSnippet(of: q)
        }
        messages.append(optimistic)
        messageIDs.insert(tempID)
        invalidateTimeline()
        receiptStatus[tempID] = .sent

        let client = self.client
        let cjid = chatJID
        let eph = ephemeralExpirationSeconds
        // Precompute MainActor-isolated quote-field helpers before the
        // detached task so the closure stays nonisolated.
        let quotedKindStr = replyTo.map { Self.quotedKind(of: $0) }
        let quotedSnippetStr = replyTo.map { Self.quotedSnippet(of: $0) }

        do {
            let res: BridgeSendResult = try await Task.detached(
                priority: .userInitiated
            ) { () -> BridgeSendResult in
                if let q = replyTo {
                    return try client.sendTextReply(
                        cjid, body,
                        quotedID: q.id,
                        quotedSenderJID: q.senderJID,
                        quotedFromMe: q.fromMe,
                        quotedKind: quotedKindStr ?? "",
                        quotedSnippet: quotedSnippetStr ?? "",
                        mentionedJIDs: mentionedJIDs,
                        ephemeralSeconds: eph)
                }
                return try client.sendText(
                    cjid, body,
                    mentionedJIDs: mentionedJIDs,
                    ephemeralSeconds: eph)
            }.value
            var real = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .text(body))
            if let q = replyTo {
                real.quotedMessageID = q.id
                real.quotedSenderJID = q.senderJID
                real.quotedFromMe = q.fromMe
                real.quotedKind = Self.quotedKind(of: q)
                real.quotedTextSnippet = Self.quotedSnippet(of: q)
            }
            if let idx = messages.firstIndex(where: { $0.id == tempID }) {
                messages[idx] = real
            } else {
                messages.append(real)
            }
            messageIDs.remove(tempID)
            messageIDs.insert(real.id)
            receiptStatus[tempID] = nil
            receiptStatus[real.id] = .sent
            invalidateTimeline()
            persistOutgoing(real, kind: "text", text: body)
        } catch {
            // Roll back optimistic append; restore composer state.
            messages.removeAll { $0.id == tempID }
            messageIDs.remove(tempID)
            receiptStatus[tempID] = nil
            invalidateTimeline()
            replyTarget = replyTo
            draft = raw
            activeMentions = mentionsSnapshot
            transientError = "Couldn't send: \(error.localizedDescription)"
        }
    }

    func ingest(_ b: BridgeMessage) {
        // Bridge emits raw (possibly `@lid` / device-suffixed) JIDs; our
        // stored `chatJID` is canonical. Match in canonical space so
        // events for this chat aren't dropped on the floor.
        guard JIDNormalize.canonical(b.chatJID, client: client) == chatJID else { return }
        if b.kind == "protocol" { return }
        // F35: allow synthetic system rows with body text through —
        // the bridge emits these for encryption-key changes +
        // disappearing-timer changes so the user sees them inline.
        if b.kind == "system", (b.text ?? "").isEmpty { return }
        // O(1) dedupe via the Set mirror — both for rows already on
        // screen and for rows queued earlier in this flush window.
        if messageIDs.contains(b.id) { return }
        if pendingIngestIDs.contains(b.id) { return }
        pendingIngestIDs.insert(b.id)
        pendingIngest.append(b)
        guard pendingIngestFlush == nil else { return }
        // F47 / F57: ingest coalesce.
        // Normal traffic — 250ms, near-real-time. During an active
        // full-history sync (chatList → session → fullSync.inFlight)
        // the row-render cost (1000+ TimelineItem id-getter calls per
        // body re-eval + RightClickCatcher.updateNSView per visible
        // bubble + receipt-dict observation cascades) saturated
        // MainActor under the original 50ms / 250ms windows; the user
        // beachballed when browsing the open conversation mid-sync.
        // Bump to 2s during sync so the open conversation gets ONE
        // big batch update per 2-second window instead of constant
        // dribble.
        let inSync = chatList?.session?.fullSync.inFlight ?? false
        let debounceMs: UInt64 = inSync ? 2000 : 250
        pendingIngestFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self else { return }
            self.flushIngest()
        }
    }

    /// Drains `pendingIngest` into `messages` in one batch. Bumps the
    /// timeline generation once for the whole batch (vs. once per
    /// event), then runs per-message side effects: SwiftData persist,
    /// auto-download, unread-receipt bookkeeping.
    @MainActor
    private func flushIngest() {
        let batch = pendingIngest
        pendingIngest.removeAll(keepingCapacity: true)
        pendingIngestIDs.removeAll(keepingCapacity: true)
        pendingIngestFlush = nil
        if batch.isEmpty { return }
        // Filter against the current Set — a path other than `ingest`
        // (e.g. an optimistic send, a forwarded-into-self append) may
        // have inserted one of these ids since the burst started.
        var newRows: [UIMessage] = []
        newRows.reserveCapacity(batch.count)
        var ingested: [BridgeMessage] = []
        ingested.reserveCapacity(batch.count)
        for b in batch {
            if messageIDs.contains(b.id) { continue }
            let m = UIMessage(b)
            newRows.append(m)
            messageIDs.insert(m.id)
            ingested.append(b)
        }
        if newRows.isEmpty { return }
        messages.append(contentsOf: newRows)
        invalidateTimeline()
        for b in ingested {
            persist(b)
            ensureDownload(for: b)
            if !b.fromMe {
                // Don't fire the receipt yet — wait until the row has
                // been on screen long enough that the user actually
                // saw it. ViewportReadModifier drives
                // `markVisibleAsRead`.
                unreadInboundIDs.insert(b.id)
            }
        }
    }

    /// Called once a MessageRow has been in the viewport for the
    /// dwell window AND the app is frontmost. Fires the read receipt
    /// and decrements the sidebar badge.
    func markVisibleAsRead(messageID: String) {
        guard unreadInboundIDs.contains(messageID) else { return }
        guard let msg = messages.first(where: { $0.id == messageID }),
              !msg.fromMe
        else {
            unreadInboundIDs.remove(messageID)
            return
        }
        unreadInboundIDs.remove(messageID)
        sendReadReceipts(for: [BridgeIDPair(msg)])
        chatList?.decrementUnread(chatJID)
    }

    /// Sends read receipts for all currently-loaded inbound messages.
    /// Called once on chat open. Groups by senderJID because whatsmeow's
    /// `MarkRead` requires a single sender per call (in groups, multiple
    /// participants may have sent the unread batch).
    func markAllAsRead() {
        let inbound = messages.filter { !$0.fromMe }
        sendReadReceipts(for: inbound.map(BridgeIDPair.init))
    }

    private struct BridgeIDPair {
        let id: String
        let senderJID: String
        init(_ m: UIMessage) {
            self.id = m.id
            self.senderJID = m.senderJID
        }
        init(_ b: BridgeMessage) {
            self.id = b.id
            self.senderJID = b.senderJID
        }
    }

    private func sendReadReceipts(for pairs: [BridgeIDPair]) {
        guard !pairs.isEmpty else { return }
        let chat = chatJID
        let client = self.client
        // Group ids by sender so each MarkRead call has a coherent sender.
        var bySender: [String: [String]] = [:]
        for p in pairs {
            bySender[p.senderJID, default: []].append(p.id)
        }
        Task.detached(priority: .utility) {
            for (sender, ids) in bySender {
                try? client.markRead(chatJID: chat, senderJID: sender, messageIDs: ids)
            }
        }
    }
    private func sendReadReceipts(for messages: [BridgeMessage]) {
        sendReadReceipts(for: messages.map(BridgeIDPair.init))
    }

    func setTyping(_ typing: Bool) {
        try? client.sendTyping(chatJID, typing)
    }

    func sendVoiceNote(_ result: VoiceRecorder.Result) async {
        do {
            let res = try client.sendVoiceNote(chatJID,
                                               path: result.url.path,
                                               duration: Int32(result.durationSec),
                                               waveform: result.waveform,
                                               ephemeralSeconds: ephemeralExpirationSeconds)
            // Move the ogg from temp into the media cache under a
            // per-message filename so the local bubble keeps playing
            // after restarts (AudioPlayerView resolves the stored
            // localPath via AVPlayer, which decodes Ogg-Opus natively).
            let persistent: URL = {
                if let dir = try? AppPaths.mediaCacheURL() {
                    return dir.appendingPathComponent("voice-\(res.messageID).ogg")
                }
                return URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("yawac-voice-\(res.messageID).ogg")
            }()
            try? FileManager.default.removeItem(at: persistent)
            try? FileManager.default.moveItem(at: result.url, to: persistent)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .media(kind: "audio",
                             caption: nil,
                             fileName: nil,
                             localPath: persistent.path))
            messages.append(m)
            messageIDs.insert(m.id)
            invalidateTimeline()
            receiptStatus[m.id] = .sent
            persistOutgoingMedia(m, kind: "audio", localPath: persistent.path)
        } catch {
            let sys = UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("voice note failed: \(error.localizedDescription)"))
            messages.append(sys)
            messageIDs.insert(sys.id)
            invalidateTimeline()
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    /// Classifies a picked file into a send kind.
    static func attachmentKind(_ url: URL) -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type else { return "document" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        return "document"
    }

    /// Stage a picked file in the composer (does NOT send). The user can add
    /// a caption, remove it, or add more before sending.
    func stageAttachment(at url: URL) {
        pendingAttachments.append(PendingAttachment(url: url, kind: Self.attachmentKind(url)))
    }

    func removePendingAttachment(_ id: PendingAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Toggle the view-once flag on a staged image/video attachment. No-op
    /// for non-media kinds (audio/document don't support view-once in WA).
    func toggleViewOnce(_ id: PendingAttachment.ID) {
        guard let idx = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        let kind = pendingAttachments[idx].kind
        guard kind == "image" || kind == "video" else { return }
        pendingAttachments[idx].viewOnce.toggle()
    }

    /// Stage a chosen location in the composer. Appends to
    /// `pendingLocations`; rendered as a chip in the composer strip and
    /// dispatched by `sendPendingAttachments`.
    func stageLocation(_ p: LocationPayload) {
        pendingLocations.append(p)
    }

    /// Stage a chosen contact in the composer. Appends to
    /// `pendingContacts`; rendered as a chip in the composer strip and
    /// dispatched by `sendPendingAttachments`.
    func stageContact(_ p: ContactPayload) {
        pendingContacts.append(p)
    }

    /// Remove a staged location by index (composer chip's "x" button).
    func removePendingLocation(at index: Int) {
        guard pendingLocations.indices.contains(index) else { return }
        pendingLocations.remove(at: index)
    }

    /// Remove a staged contact by index (composer chip's "x" button).
    func removePendingContact(at index: Int) {
        guard pendingContacts.indices.contains(index) else { return }
        pendingContacts.remove(at: index)
    }

    /// Send all staged attachments, clearing the composer. The typed caption
    /// rides on the first file attachment only; the rest send caption-less.
    /// Locations and contacts dispatch after files; they don't carry
    /// captions.
    func sendPendingAttachments() async {
        let items = pendingAttachments
        let locs = pendingLocations
        let cards = pendingContacts
        guard !items.isEmpty || !locs.isEmpty || !cards.isEmpty else { return }
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAttachments = []
        pendingLocations = []
        pendingContacts = []
        draft = ""
        for (i, item) in items.enumerated() {
            await sendOneAttachment(url: item.url, kind: item.kind,
                                    caption: i == 0 ? caption : "",
                                    viewOnce: item.viewOnce)
        }
        for loc in locs {
            await sendOneLocation(loc)
        }
        for card in cards {
            await sendOneContact(card)
        }
    }

    private func sendOneAttachment(url: URL, kind: String, caption: String,
                                   viewOnce: Bool = false) async {
        do {
            let res: BridgeSendResult
            let eph = ephemeralExpirationSeconds
            switch kind {
            case "image": res = try client.sendImage(chatJID, path: url.path, caption: caption,
                                                     ephemeralSeconds: eph,
                                                     viewOnce: viewOnce)
            case "video": res = try client.sendVideo(chatJID, path: url.path, caption: caption,
                                                     ephemeralSeconds: eph,
                                                     viewOnce: viewOnce)
            case "audio": res = try client.sendAudio(chatJID, path: url.path,
                                                     ephemeralSeconds: eph)
            default:      res = try client.sendDocument(chatJID, path: url.path, caption: caption,
                                                        ephemeralSeconds: eph)
            }
            // Own sent messages aren't echoed back by the server, so append the
            // bubble optimistically (mirrors sendDraft / sendVoiceNote). Copy the
            // picked file into the media cache so it keeps rendering after the
            // security-scoped URL is released and across restarts.
            let cached = cacheOutgoingMedia(url, messageID: res.messageID)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .media(kind: kind,
                             caption: (kind == "audio" || caption.isEmpty) ? nil : caption,
                             fileName: kind == "document" ? url.lastPathComponent : nil,
                             localPath: cached))
            messages.append(m)
            messageIDs.insert(m.id)
            localPaths[res.messageID] = cached
            invalidateTimeline()
            receiptStatus[res.messageID] = .sent
            persistOutgoingMedia(m, kind: kind, localPath: cached)
        } catch {
            let sys = UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send failed: \(error.localizedDescription)"))
            messages.append(sys)
            messageIDs.insert(sys.id)
            invalidateTimeline()
        }
    }

    /// Dispatch a single staged location through the bridge and append an
    /// optimistic bubble. Mirrors the file-send error path: a system row
    /// is appended on failure so the user sees the surface.
    private func sendOneLocation(_ loc: LocationPayload) async {
        do {
            let res = try client.sendLocation(
                chatJID: chatJID,
                latitude: loc.lat,
                longitude: loc.lng,
                name: loc.name,
                address: loc.address,
                ephemeralSeconds: ephemeralExpirationSeconds)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .location(loc, isLive: false, sequence: nil))
            messages.append(m)
            messageIDs.insert(m.id)
            invalidateTimeline()
            receiptStatus[res.messageID] = .sent
            persistOutgoingLocation(m, location: loc)
        } catch {
            let sys = UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send failed: \(error.localizedDescription)"))
            messages.append(sys)
            messageIDs.insert(sys.id)
            invalidateTimeline()
        }
    }

    /// Dispatch a single staged contact-card through the bridge and append
    /// an optimistic bubble.
    private func sendOneContact(_ card: ContactPayload) async {
        do {
            let res = try client.sendContact(
                chatJID: chatJID,
                vcard: card.vcard,
                displayName: card.displayName,
                ephemeralSeconds: ephemeralExpirationSeconds)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .contact(card))
            messages.append(m)
            messageIDs.insert(m.id)
            invalidateTimeline()
            receiptStatus[res.messageID] = .sent
            persistOutgoingContact(m, contact: card)
        } catch {
            let sys = UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send failed: \(error.localizedDescription)"))
            messages.append(sys)
            messageIDs.insert(sys.id)
            invalidateTimeline()
        }
    }

    /// Copies a just-sent attachment into the media cache under a per-message
    /// filename so the optimistic bubble keeps resolving after the picked
    /// (security-scoped) URL is released. Falls back to the source path.
    private func cacheOutgoingMedia(_ src: URL, messageID: String) -> String {
        guard let dir = try? AppPaths.mediaCacheURL() else { return src.path }
        let ext = src.pathExtension.isEmpty ? "" : ".\(src.pathExtension)"
        let dest = dir.appendingPathComponent("out-\(messageID)\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            return dest.path
        } catch {
            return src.path
        }
    }

    private func persist(_ m: BridgeMessage) {
        guard let context else { return }
        // Always store the canonical chatJID so it matches loadHistory's
        // predicate (and ChatListViewModel.persistMessage, which is the
        // other write path). Without this, when CVM's event loop wins
        // the race against the sidebar's loop, the row lands with a raw
        // (device-suffixed / @lid) chatJID and is invisible to future
        // chat-open queries — the symptom is "sidebar shows new preview
        // but conversation view stays stale".
        let canonChat = JIDNormalize.canonical(m.chatJID, client: client)
        let id = m.id

        // Upsert: history-sync replays sometimes deliver fresher media
        // refs (mediaKey, directPath, hashes) than what we first
        // persisted — the original ingest may have happened before the
        // primary device's session was warm. With @Attribute(.unique)
        // a blind insert silently fails and the stale ref stays, so
        // re-attempts keep using the broken bytes. If the row already
        // exists, refresh the media fields in place instead.
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            if let ref = m.media?.ref?.json, ref != existing.mediaRefJSON {
                existing.mediaRefJSON = ref
                // Fresh ref means we should try downloading again, even
                // if we'd previously latched it as expired.
                existing.mediaExpired = false
            }
            if let p = m.media?.filePath, !p.isEmpty { existing.mediaPath = p }
            if let c = m.media?.caption, !c.isEmpty { existing.mediaCaption = c }
            if let f = m.media?.fileName, !f.isEmpty { existing.mediaFileName = f }
            if let push = m.senderPushName, !push.isEmpty {
                existing.senderPushName = push
            }
            // T12 fields: re-merge view-once / location / contact metadata so
            // history-sync replays (or live-location sequence bumps) don't
            // erase what the initial insert captured.
            if let v = m.isViewOnce { existing.isViewOnce = v }
            if let loc = m.location {
                existing.locationLat = loc.lat
                existing.locationLng = loc.lng
                if !loc.name.isEmpty { existing.locationName = loc.name }
                if !loc.address.isEmpty { existing.locationAddress = loc.address }
            }
            if m.kind == "location_live" {
                existing.locationIsLive = true
                if let seq = m.locationSequence { existing.locationSequence = seq }
            }
            if let card = m.contact {
                existing.contactVCard = card.vcard
                existing.contactDisplayName = card.displayName
            }
            try? context.save()
            return
        }

        let row = PersistedMessage(
            id: id,
            chatJID: canonChat,
            senderJID: m.senderJID,
            fromMe: m.fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
            kind: m.kind,
            text: m.text,
            mediaPath: m.media?.filePath,
            mediaCaption: m.media?.caption,
            mediaFileName: m.media?.fileName,
            mediaRefJSON: m.media?.ref?.json,
            pollJSON: m.poll?.json,
            isViewOnce: m.isViewOnce ?? false,
            viewOnceLocked: false,
            locationLat: m.location?.lat,
            locationLng: m.location?.lng,
            locationName: m.location?.name,
            locationAddress: m.location?.address,
            locationIsLive: m.kind == "location_live",
            locationSequence: m.locationSequence,
            contactVCard: m.contact?.vcard,
            contactDisplayName: m.contact?.displayName,
            senderPushName: m.senderPushName,
            quotedMessageID: m.quoted?.messageID,
            quotedSenderJID: m.quoted?.senderJID,
            quotedFromMe: m.quoted?.fromMe ?? false,
            quotedTextSnippet: m.quoted?.snippet,
            quotedKind: m.quoted?.kind,
            isForwarded: m.isForwarded ?? false,
            audioWaveform: m.media?.waveform.flatMap { Data(base64Encoded: $0) },
            isPTT: m.media?.isPTT ?? false)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    private func persistOutgoing(_ m: UIMessage, kind: String, text: String?) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: kind, text: text,
            quotedMessageID: m.quotedMessageID,
            quotedSenderJID: m.quotedSenderJID,
            quotedFromMe: m.quotedFromMe,
            quotedTextSnippet: m.quotedTextSnippet,
            quotedKind: m.quotedKind)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    func sendPoll(question: String,
                  options: [String],
                  allowMultiple: Bool) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !q.isEmpty, opts.count >= 2, opts.count <= 12 else { return }

        let selectable = allowMultiple ? 0 : 1
        do {
            let res = try client.sendPollCreation(
                chatJID,
                question: q,
                options: opts,
                selectableCount: selectable,
                ephemeralSeconds: ephemeralExpirationSeconds)

            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .poll(question: res.poll.question,
                            options: res.poll.options,
                            selectableCount: res.poll.selectableCount))

            messages.append(m)
            messageIDs.insert(m.id)
            invalidateTimeline()
            receiptStatus[m.id] = .sent
            persistOutgoingPoll(m, pollJSON: res.poll.json ?? "")
        } catch {
            transientError =
                "Couldn't create poll: \(error.localizedDescription)"
        }
    }

    private func persistOutgoingPoll(_ m: UIMessage, pollJSON: String) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id,
            chatJID: m.chatJID,
            senderJID: m.senderJID,
            fromMe: m.fromMe,
            timestamp: m.timestamp,
            kind: "poll",
            text: nil,
            pollJSON: pollJSON)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    /// Outbound-location persistence. Stores lat/lng + name/address so
    /// the bubble survives chat switches / app restarts.
    private func persistOutgoingLocation(_ m: UIMessage, location: LocationPayload) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: "location",
            text: nil,
            locationLat: location.lat,
            locationLng: location.lng,
            locationName: location.name,
            locationAddress: location.address,
            locationIsLive: false)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    /// Outbound-contact persistence. Stores the vCard payload + parsed
    /// display name.
    private func persistOutgoingContact(_ m: UIMessage, contact: ContactPayload) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: "contact",
            text: nil,
            contactVCard: contact.vcard,
            contactDisplayName: contact.displayName)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    /// Outbound-media persistence. Carries the local file path so the
    /// bubble survives chat switches / app restarts and the audio /
    /// image / video keeps rendering from disk without re-download.
    private func persistOutgoingMedia(_ m: UIMessage, kind: String, localPath: String) {
        guard let context else { return }
        // Mine caption + filename out of the UIMessage so the persisted
        // row keeps them across reload. Earlier builds dropped both,
        // surfacing a "Document" placeholder on reload.
        var caption: String? = nil
        var fileName: String? = nil
        if case .media(_, let cap, let name, _, _, _) = m.body {
            caption = cap
            fileName = name
        }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: kind, text: nil,
            mediaPath: localPath,
            mediaCaption: caption,
            mediaFileName: fileName,
            quotedMessageID: m.quotedMessageID,
            quotedSenderJID: m.quotedSenderJID,
            quotedFromMe: m.quotedFromMe,
            quotedTextSnippet: m.quotedTextSnippet,
            quotedKind: m.quotedKind)
        context.insert(row)
        try? context.save()
        MessageIndex.shared.upsert(row.indexFields)
    }

    func saveEdit(_ newBody: String) async {
        guard let m = editTarget else { return }
        let trimmed = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let current: String = {
            if case .text(let t) = m.body { return t }
            return ""
        }()
        guard !trimmed.isEmpty, trimmed != current else {
            cancelCompose()
            return
        }
        let mentionsSnapshot = activeMentions
        activeMentions = []
        let allP = (groupParticipants ?? []).map(\.jid)
        let (body, mentionedJIDs) = Self.encodeMentions(
            body: trimmed, mentions: mentionsSnapshot, allParticipants: allP)
        do {
            _ = try client.editText(chatJID, m.id, body,
                                    mentionedJIDs: mentionedJIDs,
                                    ephemeralSeconds: ephemeralExpirationSeconds)
            applyLocalEdit(messageID: m.id, newText: body, at: Date())
            editTarget = nil
        } catch {
            activeMentions = mentionsSnapshot
            transientError = "Edit not accepted: \(error.localizedDescription)"
        }
    }

    func deleteForEveryone(_ msg: UIMessage) async {
        do {
            _ = try client.revokeMessage(chatJID, msg.id, msg.senderJID, msg.fromMe)
            applyLocalRevoke(messageID: msg.id, by: msg.senderJID, at: Date())
        } catch {
            transientError = "Couldn't delete for everyone: \(error.localizedDescription)"
        }
    }

    func deleteForMe(_ msg: UIMessage) {
        if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
            messages[idx].locallyDeleted = true
            invalidateTimeline()
        }
        persistLocallyDeleted(messageID: msg.id, value: true)
        chatList?.refreshPreview(chatJID: chatJID)
    }

    private var pendingEdits:   OrderedDict<String, (text: String, ts: Date)> = .init(cap: 256)
    private var pendingRevokes: OrderedDict<String, (by: String, ts: Date)>   = .init(cap: 256)

    var pendingEditsCount: Int { pendingEdits.count }
    var pendingRevokesCount: Int { pendingRevokes.count }

    func applyIncomingEdit(chatJID: String, messageID: String, newText: String, at: Date) {
        guard JIDNormalize.canonical(chatJID, client: client) == self.chatJID else { return }
        if messages.contains(where: { $0.id == messageID }) {
            applyLocalEdit(messageID: messageID, newText: newText, at: at)
        } else {
            pendingEdits[messageID] = (newText, at)
        }
    }

    func applyIncomingRevoke(chatJID: String, messageID: String, revokedBy: String, at: Date) {
        guard JIDNormalize.canonical(chatJID, client: client) == self.chatJID else { return }
        if messages.contains(where: { $0.id == messageID }) {
            applyLocalRevoke(messageID: messageID, by: revokedBy, at: at)
        } else {
            pendingRevokes[messageID] = (revokedBy, at)
        }
    }

    /// Apply a peer-device delete-for-me sync. Hides the row locally
    /// without sending anything back; matches the in-app
    /// `deleteForMe(_:)` semantics.
    func applyIncomingLocalDelete(chatJID: String, messageID: String) {
        guard JIDNormalize.canonical(chatJID, client: client) == self.chatJID else { return }
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].locallyDeleted = true
            invalidateTimeline()
        }
        persistLocallyDeleted(messageID: messageID, value: true)
        chatList?.refreshPreview(chatJID: self.chatJID)
    }

    func replayPendingForLoadedRows() {
        let edits = pendingEdits
        let revokes = pendingRevokes
        for m in messages {
            if let p = edits[m.id] {
                applyLocalEdit(messageID: m.id, newText: p.text, at: p.ts)
                pendingEdits.removeValue(forKey: m.id)
            }
            if let r = revokes[m.id] {
                applyLocalRevoke(messageID: m.id, by: r.by, at: r.ts)
                pendingRevokes.removeValue(forKey: m.id)
            }
        }
    }

    private func applyLocalEdit(messageID: String, newText: String, at: Date) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            let old = messages[idx]
            // UIMessage.body is a let; reconstruct with the new body.
            var r = UIMessage(
                id: old.id, chatJID: old.chatJID,
                senderJID: old.senderJID, fromMe: old.fromMe,
                timestamp: old.timestamp, body: .text(newText))
            // Preserve mutable metadata.
            r.quotedMessageID = old.quotedMessageID
            r.quotedSenderJID = old.quotedSenderJID
            r.quotedFromMe = old.quotedFromMe
            r.quotedTextSnippet = old.quotedTextSnippet
            r.quotedKind = old.quotedKind
            r.revokedAt = old.revokedAt
            r.revokedBy = old.revokedBy
            r.locallyDeleted = old.locallyDeleted
            r.editedAt = at
            messages[idx] = r
            invalidateTimeline()
        }
        persistEdit(messageID: messageID, newText: newText, editedAt: at)
        chatList?.refreshPreview(chatJID: chatJID)
    }

    private func applyLocalRevoke(messageID: String, by jid: String, at: Date) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].revokedAt = at
            messages[idx].revokedBy = jid
            // Bubble rendering uses revokedAt as the gate; body stays as-is.
            invalidateTimeline()
        }
        persistRevoke(messageID: messageID, revokedBy: jid, revokedAt: at)
        chatList?.refreshPreview(chatJID: chatJID)
    }

    private func persistEdit(messageID: String, newText: String, editedAt: Date) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.text = newText
            row.editedAt = editedAt
            try? context.save()
        }
    }

    private func persistRevoke(messageID: String, revokedBy: String, revokedAt: Date) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.revokedAt = revokedAt
            row.revokedBy = revokedBy
            try? context.save()
            MessageIndex.shared.upsert(row.indexFields)
        }
    }

    private func persistLocallyDeleted(messageID: String, value: Bool) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.locallyDeleted = value
            try? context.save()
            MessageIndex.shared.upsert(row.indexFields)
        }
    }

    /// Emoji aggregated for a message (one per unique sender, latest emoji wins).
    func reactions(for messageID: String) -> [String] {
        Array((reactionsBySender[messageID] ?? [:]).values)
    }

    /// Senders grouped by emoji for a message — chips use this to surface
    /// who reacted with what on hover/popover.
    func reactors(for messageID: String) -> [String: [String]] {
        guard let bySender = reactionsBySender[messageID] else { return [:] }
        var out: [String: [String]] = [:]
        for (senderJID, emoji) in bySender {
            out[emoji, default: []].append(senderJID)
        }
        return out
    }

    /// Per-option vote counts for a given poll, keyed by option hash.
    func voteCounts(for pollMessageID: String) -> [String: Int] {
        guard let byHash = pollVotes[pollMessageID] else { return [:] }
        var out: [String: Int] = [:]
        for (hash, voters) in byHash {
            out[hash] = voters.count
        }
        return out
    }

    /// Per-option voter JIDs (sorted) for a given poll, keyed by option
    /// hash. The Swift side renders these via `mentionResolver` so the
    /// list shows display names rather than raw JIDs.
    func voters(for pollMessageID: String) -> [String: [String]] {
        guard let byHash = pollVotes[pollMessageID] else { return [:] }
        var out: [String: [String]] = [:]
        for (hash, voters) in byHash {
            out[hash] = voters.sorted()
        }
        return out
    }

    /// Option hashes the current user has selected (used to highlight the
    /// radio/checkbox in the poll UI). Matches against the account's own
    /// JID — the phone's echo of our own vote comes back with that JID
    /// (not "me"), and historical hydrated votes are keyed the same way.
    func mySelections(for pollMessageID: String) -> Set<String> {
        guard let byHash = pollVotes[pollMessageID] else { return [] }
        let me = client.ownJID
        guard !me.isEmpty else { return [] }
        var out: Set<String> = []
        for (hash, voters) in byHash where voters.contains(me) {
            out.insert(hash)
        }
        return out
    }

    func applyPollVote(pollMessageID: String, voterJID: String, optionHashes: [String]) {
        var byHash = pollVotes[pollMessageID] ?? [:]
        // A new vote from this voter replaces any prior selections — matches
        // WhatsApp semantics for both single- and multi-select polls.
        for hash in byHash.keys {
            byHash[hash]?.remove(voterJID)
            if byHash[hash]?.isEmpty == true {
                byHash.removeValue(forKey: hash)
            }
        }
        for hash in optionHashes {
            var set = byHash[hash] ?? []
            set.insert(voterJID)
            byHash[hash] = set
        }
        if byHash.isEmpty {
            pollVotes.removeValue(forKey: pollMessageID)
        } else {
            pollVotes[pollMessageID] = byHash
        }
    }

    /// Cast a vote on the poll with the given message ID. `hashes` is the
    /// list of option hashes the user picked; `options` is the full option
    /// list from the original poll so the bridge can map hashes → names.
    func castVote(messageID: String,
                  hashes: [String],
                  options: [BridgePollOption],
                  pollSenderJID: String,
                  pollFromMe: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // For our own polls UIMessage.senderJID is the "me" sentinel,
            // but whatsmeow's vote-encryption needs the real bare JID
            // (that's the key it stored the message-secret under in
            // PutMessageSecret). Resolve fromMe → ownJID before crossing
            // the bridge.
            let resolvedSender = pollFromMe ? self.client.ownJID : pollSenderJID
            do {
                _ = try self.client.sendPollVote(
                    chatJID: self.chatJID,
                    pollMsgID: messageID,
                    pollSenderJID: resolvedSender,
                    pollFromMe: pollFromMe,
                    optionHashes: hashes,
                    pollOptions: options,
                    ephemeralSeconds: self.ephemeralExpirationSeconds)
                // Optimistically tally our own vote so the bubble updates
                // immediately. Use the account's bare JID so the phone's
                // PollUpdate echo coalesces with this entry instead of
                // double-counting.
                let me = self.client.ownJID
                if !me.isEmpty {
                    self.applyPollVote(pollMessageID: messageID,
                                       voterJID: me,
                                       optionHashes: hashes)
                    // Persist our own optimistic vote — SessionViewModel's
                    // global PollVote sink only sees inbound events, and
                    // whatsmeow doesn't echo our own sent messages back as
                    // events. Without this the radio "forgets" itself on
                    // restart.
                    let json = (try? JSONEncoder().encode(hashes))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    let chat = self.chatJID
                    Task.detached(priority: .utility) {
                        SQLiteDedupe.upsertPollVote(
                            chatJID: chat,
                            pollMessageID: messageID,
                            voterJID: me,
                            optionHashesJSON: json,
                            timestamp: Date())
                    }
                }
            } catch {
                let sys = UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("vote failed: \(error.localizedDescription)"))
                self.messages.append(sys)
                self.messageIDs.insert(sys.id)
                self.invalidateTimeline()
            }
        }
    }

    /// Post or clear our reaction on a target message. emoji="" clears it.
    /// Tallies optimistically under voter id "me" — matches castVote.
    private func persistReactionLocal(_ r: BridgeReaction) {
        guard let context else { return }
        let id = r.targetMessageID
        let sender = r.senderJID
        let descriptor = FetchDescriptor<PersistedReaction>(
            predicate: #Predicate {
                $0.targetMessageID == id && $0.senderJID == sender
            })
        let ts = Date(timeIntervalSince1970: TimeInterval(r.timestamp))
        if r.emoji.isEmpty {
            if let row = try? context.fetch(descriptor).first {
                context.delete(row)
            }
        } else if let existing = try? context.fetch(descriptor).first {
            existing.emoji = r.emoji
            existing.timestamp = ts
        } else {
            let row = PersistedReaction(
                chatJID: JIDNormalize.bare(r.chatJID),
                targetMessageID: r.targetMessageID,
                senderJID: r.senderJID,
                emoji: r.emoji,
                timestamp: ts)
            context.insert(row)
        }
        try? context.save()
    }

    func sendReaction(messageID: String,
                      targetSenderJID: String,
                      targetFromMe: Bool,
                      emoji: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try self.client.sendReaction(
                    chatJID: self.chatJID,
                    targetMsgID: messageID,
                    targetSenderJID: targetSenderJID,
                    targetFromMe: targetFromMe,
                    emoji: emoji,
                    ephemeralSeconds: self.ephemeralExpirationSeconds)
                let rx = BridgeReaction(
                    chatJID: self.chatJID,
                    targetMessageID: messageID,
                    targetFromMe: targetFromMe,
                    senderJID: "me",
                    emoji: emoji,
                    timestamp: Int64(Date().timeIntervalSince1970))
                self.applyReaction(rx)
                self.persistReactionLocal(rx)
            } catch {
                let sys = UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("reaction failed: \(error.localizedDescription)"))
                self.messages.append(sys)
                self.messageIDs.insert(sys.id)
                self.invalidateTimeline()
            }
        }
    }

    /// The current user's reaction on a message, if any. Used by MessageRow
    /// to highlight the active emoji in the quick-pick menu.
    func myReaction(for messageID: String) -> String? {
        reactionsBySender[messageID]?["me"]
    }

    /// Toggle the starred state on a message. Sends an appstate patch
    /// to WhatsApp (which fans out to the user's other devices) and
    /// mutates the row optimistically — peer-device echoes arrive as
    /// `messageStarred` events and converge on the same row via
    /// `applyIncomingStar`.
    func starMessage(_ msg: UIMessage, starred: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.client.starMessage(
                    chatJID: self.chatJID,
                    targetMsgID: msg.id,
                    targetSenderJID: msg.senderJID,
                    targetFromMe: msg.fromMe,
                    starred: starred)
                let when = Date()
                self.applyLocalStar(messageID: msg.id,
                                    starredAt: starred ? when : nil)
            } catch {
                let sys = UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("star failed: \(error.localizedDescription)"))
                self.messages.append(sys)
                self.messageIDs.insert(sys.id)
                self.invalidateTimeline()
            }
        }
    }

    func applyIncomingStar(chatJID: String, messageID: String,
                           starred: Bool, at: Date) {
        guard JIDNormalize.canonical(chatJID, client: client) == self.chatJID else { return }
        applyLocalStar(messageID: messageID,
                       starredAt: starred ? at : nil)
    }

    private func applyLocalStar(messageID: String, starredAt: Date?) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].starredAt = starredAt
            invalidateTimeline()
        }
        persistStar(messageID: messageID, starredAt: starredAt)
    }

    private func persistStar(messageID: String, starredAt: Date?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.starredAt = starredAt
            try? context.save()
        }
    }

    /// View-once reveal: flip the persisted row's `viewOnceLocked` +
    /// delete the on-disk media via `ViewOnceReveal.reveal(_:)`, then
    /// mirror the lock onto the in-memory UIMessage so the row flips
    /// to its locked terminal state without waiting for a reload.
    @MainActor
    func revealViewOnce(messageID: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        guard let row = try? context.fetch(descriptor).first else { return }
        ViewOnceReveal.reveal(row)
        try? context.save()
        // Drop any cached local path so re-renders don't try to load
        // the file we just deleted.
        localPaths.removeValue(forKey: messageID)
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].viewOnceLocked = true
        }
        invalidateTimeline()
    }

    /// The newest currently-pinned message in this chat, or nil. The
    /// banner above the conversation shows this row's snippet and
    /// jumps to it on tap. WhatsApp allows multiple pinned messages;
    /// we surface the most recent and rely on the message list /
    /// info pane for the rest.
    var pinnedBannerMessage: UIMessage? {
        messages.filter { $0.pinnedAt != nil
                       && $0.revokedAt == nil
                       && !$0.locallyDeleted }
            .max { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    /// Toggle in-chat pin. Sends a PinInChatMessage stanza — every
    /// participant receives it as a regular message event and the
    /// bridge routes it to `applyIncomingMessagePin`, which converges
    /// with our optimistic mutation here.
    func pinMessage(_ msg: UIMessage, pinned: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try self.client.pinMessageInChat(
                    chatJID: self.chatJID,
                    targetMsgID: msg.id,
                    targetSenderJID: msg.senderJID,
                    targetFromMe: msg.fromMe,
                    pinned: pinned)
                let when = Date()
                self.applyLocalMessagePin(messageID: msg.id,
                                          pinnedAt: pinned ? when : nil)
            } catch {
                let sys = UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("pin failed: \(error.localizedDescription)"))
                self.messages.append(sys)
                self.messageIDs.insert(sys.id)
                self.invalidateTimeline()
            }
        }
    }

    func applyIncomingMessagePin(chatJID: String, targetMessageID: String,
                                 pinned: Bool, at: Date) {
        guard JIDNormalize.canonical(chatJID, client: client) == self.chatJID else { return }
        applyLocalMessagePin(messageID: targetMessageID,
                             pinnedAt: pinned ? at : nil)
    }

    private func applyLocalMessagePin(messageID: String, pinnedAt: Date?) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].pinnedAt = pinnedAt
            invalidateTimeline()
        }
        persistMessagePin(messageID: messageID, pinnedAt: pinnedAt)
    }

    private func persistMessagePin(messageID: String, pinnedAt: Date?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.pinnedAt = pinnedAt
            try? context.save()
        }
    }

    func applyReaction(_ r: BridgeReaction) {
        guard JIDNormalize.canonical(r.chatJID, client: client) == chatJID else { return }
        var byMsg = reactionsBySender[r.targetMessageID] ?? [:]
        if r.emoji.isEmpty {
            byMsg.removeValue(forKey: r.senderJID)
        } else {
            byMsg[r.senderJID] = r.emoji
        }
        if byMsg.isEmpty {
            reactionsBySender.removeValue(forKey: r.targetMessageID)
        } else {
            reactionsBySender[r.targetMessageID] = byMsg
        }
        // F54: reactions extend a message bubble's content (reaction strip
        // below the bubble) but don't change `messages.count`, so the
        // ConversationView's `.onChange(of: vm.messages.count)` auto-scroll
        // hook never fires. Bumping the timeline generation lets the view
        // observe a single "content might have moved" signal and reapply
        // the scroll-to-bottom-if-atBottom logic.
        invalidateTimeline()
    }

    // F52: pending receipt queue + 50ms debounce. Previously every
    // .receipt event from the bridge ran `receiptStatus[id] = status`
    // immediately, and a single multi-ID receipt did N subscript
    // writes — each one invalidates every observer of receiptStatus
    // (SwiftUI Observation cannot track per-key Dict reads). During
    // sync bursts that translated into 10s-100s of body re-evals per
    // second on every visible MessageRow. Batch into a single flush
    // window so a burst lands as one merged write.
    @ObservationIgnored private var pendingReceipts: [(id: String, status: UIMessage.Status)] = []
    @ObservationIgnored private var pendingReceiptFlush: Task<Void, Never>?

    func applyReceipt(_ r: BridgeReceipt) {
        let status: UIMessage.Status
        switch r.status {
        case "read":      status = .read
        case "played":    status = .played
        case "delivered": status = .delivered
        default:          status = .sent
        }
        for id in r.messageIDs {
            pendingReceipts.append((id, status))
        }
        guard pendingReceiptFlush == nil else { return }
        pendingReceiptFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.flushReceipts()
        }
    }

    @MainActor
    private func flushReceipts() {
        let batch = pendingReceipts
        pendingReceipts.removeAll(keepingCapacity: true)
        pendingReceiptFlush = nil
        if batch.isEmpty { return }
        // Resolve to final-status-per-id before writing so a burst that
        // bumps sent→delivered→read collapses to one subscript write.
        var resolved: [String: UIMessage.Status] = [:]
        for (id, status) in batch {
            if let existing = resolved[id] {
                if rank(status) > rank(existing) { resolved[id] = status }
            } else {
                resolved[id] = status
            }
        }
        for (id, status) in resolved {
            if let existing = receiptStatus[id] {
                if rank(status) > rank(existing) {
                    receiptStatus[id] = status
                }
            } else {
                receiptStatus[id] = status
            }
        }
    }

    private func rank(_ s: UIMessage.Status) -> Int {
        switch s {
        case .sent:      return 0
        case .delivered: return 1
        case .played:    return 2
        case .read:      return 3
        }
    }

    // MARK: - Draft persistence

    private var draftSaveTask: Task<Void, Never>?

    /// Debounced PersistedChat.draft write triggered by every `draft`
    /// mutation. Coalesces rapid typing into a single SwiftData save
    /// after the user pauses for 500 ms. Send / saveEdit set `draft = ""`,
    /// which lands here too and persists `nil` (cleared).
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let snapshot = draft
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.persistDraft(snapshot)
        }
    }

    private func persistDraft(_ text: String) {
        guard let context else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : text
        let jid = chatJID
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        guard let row = try? context.fetch(descriptor).first,
              row.draft != value else { return }
        row.draft = value
        try? context.save()
    }

    /// Called from loadHistory once the chat opens. Pulls the persisted
    /// draft into `vm.draft` so the composer fills in immediately.
    /// Idempotent — re-entry during refreshes is harmless.
    func restoreDraftIfNeeded() {
        guard draft.isEmpty, let context else { return }
        let jid = chatJID
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        if let row = try? context.fetch(descriptor).first,
           let saved = row.draft, !saved.isEmpty {
            draft = saved
        }
    }

    // MARK: - Mentions

    nonisolated struct ActiveMention: Equatable {
        let displayName: String
        let jid: String   // MentionPickerViewModel.everyoneSentinelJID for @everyone
    }

    /// Live picker state shared with ComposerView.
    var picker = MentionPickerViewModel()

    /// Captures every successful pick during the current draft session;
    /// cleared on a successful send / edit.
    var activeMentions: [ActiveMention] = []

    /// Cached group participants for this chat. Lazily fetched on first
    /// composer `@` keystroke. nil = not yet fetched; [] = fetched empty
    /// or non-group.
    var groupParticipants: [BridgeParticipantModel]?

    /// Pure helper — testable without spinning up a CVM. Walks `mentions`
    /// in order, swapping each `@<displayName>` in `body` for `@<phone>`
    /// (or expanding `@everyone` to every participant) and returning a
    /// de-duplicated `mentionedJIDs` list.
    nonisolated static func encodeMentions(
        body: String,
        mentions: [ActiveMention],
        allParticipants: [String]
    ) -> (String, [String]) {
        var out = body
        var jids: [String] = []
        for m in mentions {
            let needle = "@\(m.displayName)"
            if m.jid == MentionPickerViewModel.everyoneSentinelJID {
                if out.contains(needle) {
                    jids.append(contentsOf: allParticipants)
                }
            } else {
                let replacement = "@" + Self.phoneDigits(jid: m.jid)
                if let r = out.range(of: needle) {
                    out.replaceSubrange(r, with: replacement)
                    jids.append(m.jid)
                }
            }
        }
        var seen = Set<String>()
        let deduped = jids.filter { seen.insert($0).inserted }
        return (out, deduped)
    }

    /// Resolves the disappearing-message timer (seconds) of an arbitrary
    /// chat by JID. Used by `executeForward` so each outbound forward
    /// inherits its **destination** chat's timer, not the source
    /// conversation's `self.ephemeralExpirationSeconds`. Falls back to 0
    /// (non-disappearing) when the chat isn't in the sidebar yet.
    private func dstEphemeralSec(_ dstJID: String) -> Int32 {
        chatList?.chats.first(where: { $0.jid == dstJID })?
            .ephemeralExpirationSeconds ?? 0
    }

    /// Substring before the first `@` of a JID — the phone or LID number
    /// WhatsApp wants in the body text. Returns the full string if `@`
    /// not present (defensive).
    nonisolated private static func phoneDigits(jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        return String(jid[..<at])
    }

    /// Lazily fetches group participants for this chat. No-op for 1:1
    /// chats. Caller awaits before opening the mention picker; UI shows
    /// a "Loading…" row in the strip while in-flight.
    func loadGroupParticipantsIfNeeded() async {
        if groupParticipants != nil { return }
        guard chatJID.hasSuffix("@g.us") else {
            groupParticipants = []
            return
        }
        do {
            let info = try client.getGroupInfo(jid: chatJID)
            self.groupParticipants = info.participants
            // Side-effect: keep chat-list's groupDescription in sync
            // with the freshly-fetched group topic.
            if !info.topic.isEmpty {
                chatList?.applyLocalGroupInfo(chatJID: chatJID,
                                              name: nil,
                                              description: info.topic)
            }
        } catch {
            self.groupParticipants = []
        }
    }
}
