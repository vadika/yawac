import Foundation

struct LocationPayload: Hashable, Sendable {
    let lat: Double
    let lng: Double
    let name: String
    let address: String
}

struct ContactPayload: Hashable, Sendable {
    let jid: String
    let displayName: String
    let phone: String
    // TODO Task 14: switch to computed `var vcard: String { VCardBuilder.build(...) }`
    // once VCardBuilder lands; for now we accept a prebuilt vCard string.
    let vcard: String
}

struct UIMessage: Identifiable, Hashable, Sendable {
    let id: String
    let chatJID: String
    let senderJID: String
    let fromMe: Bool
    let timestamp: Date
    let body: Body
    var quotedMessageID: String? = nil
    var quotedSenderJID: String? = nil
    var quotedFromMe: Bool = false
    var quotedTextSnippet: String? = nil
    var quotedKind: String? = nil
    var editedAt: Date? = nil
    var revokedAt: Date? = nil
    var revokedBy: String? = nil
    var locallyDeleted: Bool = false
    var starredAt: Date? = nil
    var pinnedAt: Date? = nil
    var isForwarded: Bool = false
    var isViewOnce: Bool = false
    /// Mirrors PersistedMessage.viewOnceLocked — set once the user has
    /// revealed the view-once envelope so we permanently render the
    /// "You viewed this once" lock instead of the reveal CTA. Default
    /// false; populated from the persisted row in loadHistory + after
    /// ViewOnceReveal.reveal(_:) flips it.
    var viewOnceLocked: Bool = false

    enum Body: Hashable, Sendable {
        case text(String)
        /// `waveform` carries the raw amplitude bytes (WhatsApp ships 64
        /// values 0-100) for voice notes — nil for older messages and
        /// non-audio kinds. `isPTT` flips the audio bubble between the
        /// vertical-bar waveform view (true) and the plain progress
        /// bar (false / music clip).
        case media(kind: String, caption: String?, fileName: String?,
                   localPath: String?, waveform: Data? = nil,
                   isPTT: Bool = false)
        case poll(question: String, options: [BridgePollOption], selectableCount: Int)
        case location(LocationPayload, isLive: Bool, sequence: Int64?)
        case contact(ContactPayload)
        case system(String)
    }
}

extension UIMessage {
    enum Status: Hashable, Sendable {
        case sent
        case delivered
        case read
        case played
    }
}

extension UIMessage {
    init(_ b: BridgeMessage) {
        self.id = b.id
        self.chatJID = b.chatJID
        self.senderJID = b.senderJID
        self.fromMe = b.fromMe
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(b.timestamp))
        switch b.kind {
        case "text":
            self.body = .text(b.text ?? "")
        case "image", "video", "audio", "document", "sticker":
            self.body = .media(kind: b.kind,
                               caption: b.media?.caption,
                               fileName: b.media?.fileName,
                               localPath: b.media?.filePath,
                               waveform: b.media?.waveform.flatMap {
                                   Data(base64Encoded: $0)
                               },
                               isPTT: b.media?.isPTT ?? false)
        case "poll":
            if let p = b.poll {
                self.body = .poll(question: p.question,
                                  options: p.options,
                                  selectableCount: p.selectableCount)
            } else {
                self.body = .system(b.kind)
            }
        case "location":
            if let loc = b.location {
                self.body = .location(
                    LocationPayload(lat: loc.lat, lng: loc.lng,
                                    name: loc.name, address: loc.address),
                    isLive: false, sequence: nil)
            } else {
                self.body = .system("(location)")
            }
        case "location_live":
            if let loc = b.location {
                self.body = .location(
                    LocationPayload(lat: loc.lat, lng: loc.lng,
                                    name: loc.name, address: loc.address),
                    isLive: true, sequence: b.locationSequence)
            } else {
                self.body = .system("(live location)")
            }
        case "contact":
            if let c = b.contact {
                let waid = VCardBuilder.parseWAID(c.vcard) ?? ""
                let jid = waid.isEmpty ? "" : "\(waid)@s.whatsapp.net"
                let phone = waid.isEmpty ? "" : "+\(waid)"
                self.body = .contact(ContactPayload(
                    jid: jid,
                    displayName: c.displayName,
                    phone: phone,
                    vcard: c.vcard))
            } else {
                self.body = .system("(contact)")
            }
        default:
            self.body = .system(b.kind)
        }
        if let q = b.quoted {
            self.quotedMessageID = q.messageID
            self.quotedSenderJID = q.senderJID
            self.quotedFromMe = q.fromMe
            self.quotedTextSnippet = q.snippet
            self.quotedKind = q.kind
        }
        self.isForwarded = b.isForwarded ?? false
        self.isViewOnce = b.isViewOnce ?? false
    }
}
