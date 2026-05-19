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
    var downloadErrors: [String: String] = [:]
    let client: WAClient
    private let context: ModelContext?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    // One retry-request per message id per session — avoids hammering the
    // phone with redundant SendMediaRetryReceipt calls if download retries
    // keep failing.
    private var retriesRequested: Set<String> = []

    init(chatJID: String, client: WAClient, context: ModelContext? = nil) {
        self.chatJID = chatJID
        self.client = client
        self.context = context
    }

    /// Hard cap on initial load — large chats freeze SwiftUI's LazyVStack
    /// prefetcher if we hand it 10k+ rows at once. Newest N kept; older
    /// rows remain in storage and can be paged in later.
    static let historyLoadLimit = 500

    func loadHistory() {
        guard let context else { return }
        let jid = chatJID
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
                default:
                    body = .system(p.kind)
                }
                return UIMessage(
                    id: p.id,
                    chatJID: p.chatJID,
                    senderJID: p.senderJID,
                    fromMe: p.fromMe,
                    timestamp: p.timestamp,
                    body: body)
            }
            // Seed localPaths from any persisted media files, then kick off
            // downloads for media (images/stickers) that we don't have on disk yet.
            for p in rows {
                if let path = p.mediaPath, FileManager.default.fileExists(atPath: path) {
                    localPaths[p.id] = path
                    continue
                }
                let downloadable: Set<String> = ["image", "sticker", "video", "audio", "document"]
                guard downloadable.contains(p.kind) else { continue }
                if downloadTasks[p.id] != nil { continue }
                guard let refJSON = p.mediaRefJSON else {
                    // Persisted before mediaRefJSON column existed — no way to
                    // fetch. Surface so user isn't stuck on infinite spinner.
                    downloadErrors[p.id] = "no download info (re-pair to refresh)"
                    continue
                }
                ensureDownloadFromHistory(id: p.id, kind: p.kind, refJSON: refJSON)
            }
        }
    }

    func retryDownload(messageID: String, kind: String, refJSON: String) {
        downloadErrors[messageID] = nil
        downloadTasks[messageID]?.cancel()
        downloadTasks[messageID] = nil
        ensureDownloadFromHistory(id: messageID, kind: kind, refJSON: refJSON)
    }

    func retryHandler(for message: UIMessage) -> (() -> Void)? {
        guard case .media(let kind, _, _, _) = message.body else { return nil }
        guard let context else { return nil }
        let id = message.id
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id })
        guard let row = try? context.fetch(descriptor).first,
              let refJSON = row.mediaRefJSON else { return nil }
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

    private func ensureDownloadFromHistory(id: String, kind: String, refJSON: String) {
        let ext: String
        switch kind {
        case "image":    ext = "jpg"
        case "video":    ext = "mp4"
        case "audio":    ext = "ogg"
        case "document": ext = "bin"
        case "sticker":  ext = "webp"
        default:         ext = "bin"
        }
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
                    self.tryRequestMediaRetry(messageID: id, reason: reason)
                case .missingRef:
                    self.downloadErrors[id] = "no ref"
                }
            }
            self?.downloadTasks[id] = nil
        }
    }

    private func tryRequestMediaRetry(messageID: String, reason: String) {
        guard !retriesRequested.contains(messageID) else { return }
        let lower = reason.lowercased()
        guard lower.contains("403") || lower.contains("404") || lower.contains("410") else { return }
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
            downloadErrors[messageID] = "phone retry failed: \(error ?? "?")"
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
        do {
            let res = try client.sendText(chatJID, body)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .text(body))
            messages.append(m)
            receiptStatus[m.id] = .sent
            persistOutgoing(m, kind: "text", text: body)
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

    func ingest(_ b: BridgeMessage) {
        guard b.chatJID == chatJID else { return }
        // Dedupe by id (echo of fromMe send may arrive after local optimistic append)
        if messages.contains(where: { $0.id == b.id }) { return }
        messages.append(UIMessage(b))
        persist(b)
        ensureDownload(for: b)
    }

    func setTyping(_ typing: Bool) {
        try? client.sendTyping(chatJID, typing)
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
        let row = PersistedMessage(
            id: m.id,
            chatJID: m.chatJID,
            senderJID: m.senderJID,
            fromMe: m.fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
            kind: m.kind,
            text: m.text,
            mediaPath: m.media?.filePath,
            mediaCaption: m.media?.caption,
            mediaFileName: m.media?.fileName,
            mediaRefJSON: m.media?.ref?.json)
        context.insert(row)
        try? context.save()
    }

    private func persistOutgoing(_ m: UIMessage, kind: String, text: String?) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: kind, text: text)
        context.insert(row)
        try? context.save()
    }

    /// Emoji aggregated for a message (one per unique sender, latest emoji wins).
    func reactions(for messageID: String) -> [String] {
        Array((reactionsBySender[messageID] ?? [:]).values)
    }

    func applyReaction(_ r: BridgeReaction) {
        guard r.chatJID == chatJID else { return }
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
