import Foundation

extension BridgeMessage {
    /// The same payload shape enters persistence for all sending surfaces.
    init(outgoing message: UIMessage, ownJID: String, mediaRefJSON: String? = nil) {
        var kind: String
        var text: String?
        var media: BridgeMedia?
        var poll: BridgePoll?
        var location: BridgeLocationPayload?
        var sequence: Int64?
        var contact: BridgeContactPayload?
        var contacts: BridgeContactsArrayPayload?
        switch message.body {
        case .text(let value): kind = "text"; text = value
        case .system(let value): kind = "system"; text = value
        case .media(let type, let caption, let name, let path, let waveform, let ptt):
            kind = type
            let ref = mediaRefJSON.flatMap { try? JSONDecoder().decode(BridgeMediaRef.self, from: Data($0.utf8)) }
            media = BridgeMedia(mimeType: ref?.mimetype ?? "", caption: caption, fileName: name,
                                filePath: path, width: message.mediaWidth, height: message.mediaHeight,
                                duration: nil, sizeBytes: nil, waveform: waveform?.base64EncodedString(),
                                isPTT: ptt, ref: ref)
        case .poll(let question, let options, let count):
            kind = "poll"
            poll = BridgePoll(question: question, options: options, selectableCount: count)
        case .location(let value, let live, let seq):
            kind = live ? "location_live" : "location"
            location = BridgeLocationPayload(lat: value.lat, lng: value.lng, name: value.name, address: value.address)
            sequence = seq
        case .contact(let value):
            kind = "contact"
            contact = BridgeContactPayload(vcard: value.vcard, displayName: value.displayName)
        case .contacts(let values):
            kind = "contacts"
            contacts = BridgeContactsArrayPayload(displayName: "", contacts: values.map {
                BridgeContactPayload(vcard: $0.vcard, displayName: $0.displayName)
            })
        }
        self.init(id: message.id, chatJID: message.chatJID,
                  senderJID: message.senderJID == "me" ? ownJID : message.senderJID,
                  senderPushName: nil, fromMe: message.fromMe,
                  timestamp: Int64(message.timestamp.timeIntervalSince1970), kind: kind,
                  text: text, media: media, poll: poll,
                  quoted: message.quotedMessageID.map {
                      Quoted(messageID: $0, senderJID: message.quotedSenderJID ?? "",
                             fromMe: message.quotedFromMe, kind: message.quotedKind ?? "",
                             snippet: message.quotedTextSnippet ?? "")
                  }, isForwarded: message.isForwarded, location: location, locationSequence: sequence,
                  contact: contact, contactsArray: contacts, isViewOnce: message.isViewOnce)
    }
}
