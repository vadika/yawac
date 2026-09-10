import Foundation

extension PersistedMessage {
    /// Replays enrich metadata without undoing local lifecycle state or edits.
    func merge(_ message: BridgeMessage, canonicalChatJID: String) throws {
        chatJID = canonicalChatJID
        if editedAt == nil, let value = message.text { text = value }
        if let value = message.senderPushName, !value.isEmpty { senderPushName = value }
        if message.isForwarded == true { isForwarded = true }
        if message.isViewOnce == true { isViewOnce = true }
        if let media = message.media {
            if let value = media.ref?.json, value != mediaRefJSON {
                mediaRefJSON = value
                mediaExpired = false
            }
            if !viewOnceLocked, let value = media.filePath, !value.isEmpty { mediaPath = value }
            if !viewOnceLocked, let value = media.caption { mediaCaption = value }
            if let value = media.fileName { mediaFileName = value }
            if let value = media.width, value > 0 { mediaWidth = value }
            if let value = media.height, value > 0 { mediaHeight = value }
            if let value = media.waveform.flatMap({ Data(base64Encoded: $0) }) {
                audioWaveform = value
            }
            if let value = media.isPTT { isPTT = value }
        }
        if let value = message.poll { pollJSON = value.json }
        if let value = message.quoted {
            quotedMessageID = value.messageID
            quotedSenderJID = value.senderJID
            quotedFromMe = value.fromMe
            quotedKind = value.kind
            quotedTextSnippet = value.snippet
        }
        let newerLocation = message.locationSequence.map { $0 >= (locationSequence ?? 0) } ?? (locationSequence == nil)
        if newerLocation, let value = message.location {
            locationLat = value.lat
            locationLng = value.lng
            locationName = value.name
            locationAddress = value.address
            locationIsLive = message.kind == "location_live"
            locationSequence = message.locationSequence
        }
        if let value = message.contact {
            contactVCard = value.vcard
            contactDisplayName = value.displayName
        }
        if let value = message.contactsArray {
            contactsJSON = String(data: try JSONEncoder().encode(value.contacts), encoding: .utf8)
        }
    }

    var sidebarPreview: String {
        let m = self
        if m.revokedAt != nil   { return "🚫 message deleted" }
        if m.locallyDeleted     { return "🚫 you deleted this" }
        // Kind gate BEFORE text: system rows carry body text
        // ("Encryption key with X changed.") that must never become
        // the sidebar preview.
        if m.kind == "system" || m.kind == "protocol" { return "" }
        if let t = m.text, !t.isEmpty { return t }
        switch m.kind {
        case "image":    return "📷 Photo"
        case "video":    return "🎥 Video"
        case "audio":    return "🎤 Audio"
        case "document": return "📄 Document"
        case "sticker":  return "Sticker"
        case "location": return "📍 Location"
        case "poll":     return "📊 Poll"
        case "protocol", "system": return ""
        default:         return "[\(m.kind)]"
        }
    }

    var searchable: Bool { !locallyDeleted && revokedAt == nil }
    var uiMessage: UIMessage {
        let p = self
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
        case "location", "location_live":
            body = .location(LocationPayload(lat: p.locationLat ?? 0, lng: p.locationLng ?? 0,
                                            name: p.locationName ?? "", address: p.locationAddress ?? ""),
                             isLive: p.locationIsLive, sequence: p.locationSequence)
        case "contact":
            // Rebuild contact presentation from the stored vCard.
            if let vcard = p.contactVCard {
                body = .contact(ContactPayload.fromVCard(
                    vcard, displayName: p.contactDisplayName ?? ""))
            } else {
                body = .system("(contact)")
            }
        case "contacts":
            // F104: ContactsArrayMessage row — decode the JSON-encoded
            // [BridgeContactPayload] back into `[ContactPayload]` so the
            // stacked bubble renders without a round-trip through the
            // bridge.
            if let json = p.contactsJSON,
               let data = json.data(using: .utf8),
               let arr = try? JSONDecoder().decode([BridgeContactPayload].self,
                                                    from: data) {
                let cards = arr.map {
                    ContactPayload.fromVCard($0.vcard, displayName: $0.displayName)
                }
                body = .contacts(cards)
            } else {
                body = .system("(contacts)")
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
}
