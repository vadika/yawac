import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

@Observable @MainActor
final class ConversationViewModel {
    let chatJID: String
    var messages: [UIMessage] = []
    var draft: String = ""
    var peerTyping: Bool = false
    var receiptStatus: [String: UIMessage.Status] = [:]
    var localPaths: [String: String] = [:]
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
    /// Back-ref to the chat list so mutations (edit/revoke/delete-for-me)
    /// can push an updated preview to the sidebar. Set by ConversationView
    /// when the chat becomes active.
    weak var chatList: ChatListViewModel?

    func jumpToQuoted(id: String) {
        if messages.contains(where: { $0.id == id }) {
            pendingScrollToID = id
            return
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
                          fileName: p.mediaFileName, localPath: p.mediaPath)
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
            body = .system(p.kind)
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
        m.quotedMessageID = p.quotedMessageID
        m.quotedSenderJID = p.quotedSenderJID
        m.quotedFromMe = p.quotedFromMe
        m.quotedTextSnippet = p.quotedTextSnippet
        m.quotedKind = p.quotedKind

        // Insert sorted by timestamp.
        let idx = messages.firstIndex(where: { $0.timestamp > m.timestamp }) ?? messages.count
        messages.insert(m, at: idx)
        pendingScrollToID = id
    }

    func didFinishScroll(to id: String) {
        highlightedID = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            if self.highlightedID == id { self.highlightedID = nil }
        }
    }

    private static func quotedKind(of m: UIMessage) -> String {
        switch m.body {
        case .text:                       return "text"
        case .media(let kind, _, _, _):   return kind
        case .poll:                       return "poll"
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
        case .media(let kind, let caption, let fileName, _):
            if let c = caption, !c.isEmpty { return trunc(c) }
            if kind == "document", let n = fileName, !n.isEmpty { return trunc(n) }
            return "[\(kind)]"
        case .poll(let q, _, _):
            return trunc(q)
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

    init(chatJID: String, client: WAClient, context: ModelContext? = nil) {
        self.chatJID = chatJID
        self.client = client
        self.context = context
    }

    /// Hard cap on initial load — large chats freeze SwiftUI's LazyVStack
    /// prefetcher if we hand it 10k+ rows at once. Newest N kept; older
    /// rows remain in storage and can be paged in later.
    static let historyLoadLimit = 500

    /// Message id to anchor the initial scroll position to. Set in
    /// `loadHistory` based on the chat's persisted unread count: anchors
    /// to the first unread message when there are unread messages,
    /// otherwise to the latest (bottom).
    private(set) var initialAnchorID: String?

    func loadHistory() {
        guard let context else { return }
        let jid = chatJID
        // One-shot migration: earlier builds persisted some rows with raw
        // (device-suffixed / @lid) chatJID via CVM.persist. Scrub anything
        // whose canonical form matches this chat back to canonical so the
        // primary fetch finds it. Scoped to plausibly-related rows by
        // matching on the user portion before "@".
        if let at = jid.firstIndex(of: "@") {
            let userPart = String(jid[..<at])
            let scrubDescriptor = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.chatJID != jid && $0.chatJID.contains(userPart) })
            if let scrubRows = try? context.fetch(scrubDescriptor) {
                var changed = 0
                for r in scrubRows {
                    if JIDNormalize.canonical(r.chatJID, client: client) == jid {
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
        }
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = Self.historyLoadLimit
        if let recentRows = try? context.fetch(descriptor) {
            let rows = recentRows.reversed().map { $0 }
            // Sweep legacy rows of non-displayable kinds (e.g. reactions persisted
            // by older builds before the dedicated Reaction event).
            for p in rows where p.kind == "reaction" || p.kind == "protocol" || p.kind == "system" {
                context.delete(p)
            }
            try? context.save()
            let displayable = rows.filter { p in
                p.kind != "reaction" && p.kind != "protocol" && p.kind != "system"
            }
            self.messages = displayable.map { p in
                let body: UIMessage.Body
                switch p.kind {
                case "text":
                    body = .text(p.text ?? "")
                case "image", "video", "audio", "document", "sticker":
                    body = .media(kind: p.kind, caption: p.mediaCaption, fileName: p.mediaFileName, localPath: p.mediaPath)
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
                    body = .system(p.kind)
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
                m.quotedMessageID = p.quotedMessageID
                m.quotedSenderJID = p.quotedSenderJID
                m.quotedFromMe = p.quotedFromMe
                m.quotedTextSnippet = p.quotedTextSnippet
                m.quotedKind = p.quotedKind
                return m
            }
            // Hydrate persisted delivery status (fromMe only — receipts for
            // inbound messages aren't shown).
            for p in displayable where p.fromMe {
                switch p.deliveryStatus {
                case "delivered": receiptStatus[p.id] = .delivered
                case "played":    receiptStatus[p.id] = .played
                case "read":      receiptStatus[p.id] = .read
                default:          receiptStatus[p.id] = .sent
                }
            }

            // Hydrate reactions for the loaded messages from PersistedReaction.
            let ids = Set(displayable.map { $0.id })
            let rxDescriptor = FetchDescriptor<PersistedReaction>(
                predicate: #Predicate { ids.contains($0.targetMessageID) })
            if let rxRows = try? context.fetch(rxDescriptor) {
                for r in rxRows {
                    var byHash = reactionsBySender[r.targetMessageID] ?? [:]
                    byHash[r.senderJID] = r.emoji
                    reactionsBySender[r.targetMessageID] = byHash
                }
            }

            // Hydrate poll vote tallies. Only seed entries for polls in the
            // current window — older polls re-hydrate when scrolled back in.
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

            // Seed localPaths from any persisted media files, then kick off
            // downloads for media (images/stickers) that we don't have on disk yet.
            var expiredOnLoad: [PersistedMessage] = []
            for p in rows {
                if let path = p.mediaPath, FileManager.default.fileExists(atPath: path) {
                    localPaths[p.id] = path
                    continue
                }
                let downloadable: Set<String> = ["image", "sticker", "video", "audio", "document"]
                guard downloadable.contains(p.kind) else { continue }
                if downloadTasks[p.id] != nil { continue }

                // Fast path: probe the deterministic cache path before
                // queueing a Task. Most chats reopen with everything
                // already cached — avoids spawning hundreds of no-op
                // download tasks that flood the actor.
                if let cached = cachedFilePath(for: p) {
                    localPaths[p.id] = cached
                    continue
                }
                if p.mediaExpired {
                    // Server has aged this media out — bytes are gone.
                    // Skip re-attempts on every chat reload.
                    downloadErrors[p.id] = "media expired"
                    expiredOnLoad.append(p)
                    continue
                }

                guard let refJSON = p.mediaRefJSON else {
                    // Persisted before mediaRefJSON column existed — no way to
                    // fetch. Surface so user isn't stuck on infinite spinner.
                    downloadErrors[p.id] = "no download info (re-pair to refresh)"
                    continue
                }
                ensureDownloadFromHistory(id: p.id, kind: p.kind, refJSON: refJSON)
            }

            // Auto-refetch: once per chat per session, ask the primary
            // device to re-upload the window that covers our oldest
            // expired media. One backfill batch may bring fresh refs for
            // many messages at once.
            if !didAutoRefetchExpired, let oldest = expiredOnLoad.min(by: { $0.timestamp < $1.timestamp }) {
                didAutoRefetchExpired = true
                let ids = expiredOnLoad.map { $0.id }
                autoRefetchExpiredBatch(anchor: oldest, allIDs: ids)
            }

            // Pick initial scroll anchor: if there are unread inbound
            // messages, jump to the first one (so the user starts reading
            // where they left off). Otherwise stick to the latest.
            let pcDescriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == jid })
            let unread = (try? context.fetch(pcDescriptor))?.first?.unread ?? 0
            if unread > 0 && unread <= self.messages.count {
                let firstUnreadIdx = self.messages.count - unread
                self.initialAnchorID = self.messages[firstUnreadIdx].id
            } else {
                self.initialAnchorID = self.messages.last?.id
            }
        }
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
        guard !refreshingPolls, let context else { return }
        // Anchor at the newest message in the chat — server returns up to
        // ~50 messages older than the anchor, which includes recent polls.
        let jid = chatJID
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let anchor = (try? context.fetch(descriptor))?.first else { return }
        refreshingPolls = true
        let id = anchor.id
        let senderJID = anchor.senderJID
        let fromMe = anchor.fromMe
        let ts = Int64(anchor.timestamp.timeIntervalSince1970)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshingPolls = false }
            try? self.client.requestOlderHistory(
                chatJID: self.chatJID,
                oldestMsgID: id,
                oldestSenderJID: senderJID,
                oldestFromMe: fromMe,
                oldestTimestampSec: ts,
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
        guard !loadingOlder, !olderUnavailable, let context else { return }
        // Find oldest persisted message for this chat (not just in-memory,
        // since the in-memory cap is 500).
        let jid = chatJID
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        descriptor.fetchLimit = 1
        guard let anchor = (try? context.fetch(descriptor))?.first else { return }
        loadingOlder = true
        let id = anchor.id
        let senderJID = anchor.senderJID
        let fromMe = anchor.fromMe
        let ts = Int64(anchor.timestamp.timeIntervalSince1970)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadingOlder = false }
            do {
                try self.client.requestOlderHistory(
                    chatJID: self.chatJID,
                    oldestMsgID: id,
                    oldestSenderJID: senderJID,
                    oldestFromMe: fromMe,
                    oldestTimestampSec: ts,
                    count: 50)
                // After ~5 s, if no new rows landed, mark unavailable so the
                // user isn't given an indefinite "Loading…" UI.
                try? await Task.sleep(for: .seconds(5))
                let beforeCount = self.messages.count
                self.loadEarlier(by: 200)
                if self.messages.count == beforeCount {
                    self.olderUnavailable = true
                }
            } catch {
                self.messages.insert(UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("history request failed: \(error.localizedDescription)")
                ), at: 0)
            }
        }
    }

    /// Re-runs the loadHistory query but with a larger fetchLimit so newly-
    /// arrived older rows become visible.
    private func loadEarlier(by additional: Int) {
        let newLimit = max(messages.count + additional, Self.historyLoadLimit)
        let jid = chatJID
        guard let context else { return }
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = newLimit
        guard let recentRows = try? context.fetch(descriptor) else { return }
        let rows = recentRows.reversed().map { $0 }
        let displayable = rows.filter { p in
            p.kind != "reaction" && p.kind != "protocol" && p.kind != "system"
        }
        self.messages = displayable.map { p in
            let body: UIMessage.Body
            switch p.kind {
            case "text":
                body = .text(p.text ?? "")
            case "image", "video", "audio", "document", "sticker":
                body = .media(kind: p.kind, caption: p.mediaCaption, fileName: p.mediaFileName, localPath: p.mediaPath)
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
                body = .system(p.kind)
            }
            return UIMessage(
                id: p.id, chatJID: p.chatJID, senderJID: p.senderJID,
                fromMe: p.fromMe, timestamp: p.timestamp, body: body)
        }
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
        guard case .media(let kind, _, _, _) = message.body else { return nil }
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

    /// Returns the cached MediaCache file path if the file is already on
    /// disk, otherwise nil. Used as a fast path to skip download Task
    /// spawning on chat re-open when everything is already cached.
    private func cachedFilePath(for p: PersistedMessage) -> String? {
        let fm = FileManager.default
        let base: URL
        do {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            base = caches.appendingPathComponent("yawac-media", isDirectory: true)
        } catch { return nil }
        // Try the document's stored filename extension first.
        var candidates: [String] = []
        if p.kind == "document", let fn = p.mediaFileName {
            let e = (fn as NSString).pathExtension.lowercased()
            if !e.isEmpty { candidates.append(e) }
        }
        switch p.kind {
        case "image":    candidates.append(contentsOf: ["jpg", "png", "webp", "gif"])
        case "video":    candidates.append(contentsOf: ["mp4", "mov", "webm"])
        case "audio":    candidates.append(contentsOf: ["ogg", "mp3", "m4a", "opus", "wav"])
        case "sticker":  candidates.append("webp")
        case "document": candidates.append(contentsOf: ["pdf", "bin"])
        default:         candidates.append("bin")
        }
        for ext in candidates {
            let path = base.appendingPathComponent("\(p.id).\(ext)").path
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
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
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == messageID })
        guard let row = try? context.fetch(descriptor).first,
              let oldRefJSON = row.mediaRefJSON else { return }
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
        // Patch direct_path inside the stored MediaRef JSON so future
        // retries (and the immediate re-download below) use the fresh path.
        var refDict = (try? JSONSerialization.jsonObject(with: Data(oldRefJSON.utf8))) as? [String: Any] ?? [:]
        refDict["direct_path"] = newPath
        if let newJSON = try? JSONSerialization.data(withJSONObject: refDict),
           let s = String(data: newJSON, encoding: .utf8) {
            row.mediaRefJSON = s
            try? context.save()
            downloadErrors[messageID] = nil
            downloadTasks[messageID]?.cancel()
            downloadTasks[messageID] = nil
            ensureDownloadFromHistory(id: messageID, kind: row.kind, refJSON: s)
        }
    }

    func sendDraft() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""

        // Snapshot the reply target locally so we can clear state early.
        let replyTo = replyTarget
        replyTarget = nil

        do {
            let res: BridgeSendResult
            if let q = replyTo {
                res = try client.sendTextReply(
                    chatJID, body,
                    quotedID: q.id,
                    quotedSenderJID: q.senderJID,
                    quotedFromMe: q.fromMe,
                    quotedKind: Self.quotedKind(of: q),
                    quotedSnippet: Self.quotedSnippet(of: q))
            } else {
                res = try client.sendText(chatJID, body)
            }
            var m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .text(body))
            if let q = replyTo {
                m.quotedMessageID = q.id
                m.quotedSenderJID = q.senderJID
                m.quotedFromMe = q.fromMe
                m.quotedKind = Self.quotedKind(of: q)
                m.quotedTextSnippet = Self.quotedSnippet(of: q)
            }
            messages.append(m)
            receiptStatus[m.id] = .sent
            persistOutgoing(m, kind: "text", text: body)
        } catch {
            // Restore the reply target so the user can retry.
            replyTarget = replyTo
            draft = body
            transientError = "Couldn't send: \(error.localizedDescription)"
        }
    }

    func ingest(_ b: BridgeMessage) {
        // Bridge emits raw (possibly `@lid` / device-suffixed) JIDs; our
        // stored `chatJID` is canonical. Match in canonical space so
        // events for this chat aren't dropped on the floor.
        guard JIDNormalize.canonical(b.chatJID, client: client) == chatJID else { return }
        if b.kind == "protocol" || b.kind == "system" { return }
        if messages.contains(where: { $0.id == b.id }) { return }
        messages.append(UIMessage(b))
        persist(b)
        ensureDownload(for: b)
        if !b.fromMe {
            sendReadReceipts(for: [b])
        }
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
                                               waveform: result.waveform)
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
            receiptStatus[m.id] = .sent
            persistOutgoingMedia(m, kind: "audio", localPath: persistent.path)
        } catch {
            messages.append(UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("voice note failed: \(error.localizedDescription)")))
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    func sendAttachment(at url: URL) async {
        let caption = draft
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        do {
            let res: BridgeSendResult
            if let type {
                if type.conforms(to: .image) {
                    res = try client.sendImage(chatJID, path: url.path, caption: caption)
                } else if type.conforms(to: .movie) || type.conforms(to: .video) {
                    res = try client.sendVideo(chatJID, path: url.path, caption: caption)
                } else if type.conforms(to: .audio) {
                    res = try client.sendAudio(chatJID, path: url.path)
                } else {
                    res = try client.sendDocument(chatJID, path: url.path, caption: caption)
                }
            } else {
                res = try client.sendDocument(chatJID, path: url.path, caption: caption)
            }
            receiptStatus[res.messageID] = .sent
            draft = ""
        } catch {
            messages.append(UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send failed: \(error.localizedDescription)")))
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
            senderPushName: m.senderPushName,
            quotedMessageID: m.quoted?.messageID,
            quotedSenderJID: m.quoted?.senderJID,
            quotedFromMe: m.quoted?.fromMe ?? false,
            quotedTextSnippet: m.quoted?.snippet,
            quotedKind: m.quoted?.kind)
        context.insert(row)
        try? context.save()
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
    }

    /// Outbound-media persistence. Carries the local file path so the
    /// bubble survives chat switches / app restarts and the audio /
    /// image / video keeps rendering from disk without re-download.
    private func persistOutgoingMedia(_ m: UIMessage, kind: String, localPath: String) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: kind, text: nil,
            mediaPath: localPath,
            quotedMessageID: m.quotedMessageID,
            quotedSenderJID: m.quotedSenderJID,
            quotedFromMe: m.quotedFromMe,
            quotedTextSnippet: m.quotedTextSnippet,
            quotedKind: m.quotedKind)
        context.insert(row)
        try? context.save()
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
        do {
            _ = try client.editText(chatJID, m.id, trimmed)
            applyLocalEdit(messageID: m.id, newText: trimmed, at: Date())
            editTarget = nil
        } catch {
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
        }
        persistEdit(messageID: messageID, newText: newText, editedAt: at)
        chatList?.refreshPreview(chatJID: chatJID)
    }

    private func applyLocalRevoke(messageID: String, by jid: String, at: Date) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].revokedAt = at
            messages[idx].revokedBy = jid
            // Bubble rendering uses revokedAt as the gate; body stays as-is.
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
        }
    }

    private func persistLocallyDeleted(messageID: String, value: Bool) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == messageID })
        if let row = try? context.fetch(descriptor).first {
            row.locallyDeleted = value
            try? context.save()
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
            do {
                _ = try self.client.sendPollVote(
                    chatJID: self.chatJID,
                    pollMsgID: messageID,
                    pollSenderJID: pollSenderJID,
                    pollFromMe: pollFromMe,
                    optionHashes: hashes,
                    pollOptions: options)
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
                self.messages.append(UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("vote failed: \(error.localizedDescription)")))
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
                    emoji: emoji)
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
                self.messages.append(UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("reaction failed: \(error.localizedDescription)")))
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
                self.messages.append(UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("star failed: \(error.localizedDescription)")))
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
                self.messages.append(UIMessage(
                    id: UUID().uuidString,
                    chatJID: self.chatJID,
                    senderJID: "system",
                    fromMe: false,
                    timestamp: .now,
                    body: .system("pin failed: \(error.localizedDescription)")))
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
    }

    func applyReceipt(_ r: BridgeReceipt) {
        let status: UIMessage.Status
        switch r.status {
        case "read":      status = .read
        case "played":    status = .played
        case "delivered": status = .delivered
        default:          status = .sent
        }
        for id in r.messageIDs {
            // Only downgrade-prevent: read > delivered > sent
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
}
