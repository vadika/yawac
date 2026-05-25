package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// SendReaction posts a reaction to a target message. emoji="" removes our
// reaction. targetSenderJID is the original message's sender (group:
// participant, 1:1: chat). targetFromMe indicates whether the original was
// sent by us.
//
// Returns JSON of JSendResult.
func (c *Client) SendReaction(chatJID, targetMsgID, targetSenderJID string, targetFromMe bool, emoji string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	var sender types.JID
	if targetFromMe {
		if c.wa.Store != nil && c.wa.Store.ID != nil {
			sender = c.wa.Store.ID.ToNonAD()
		} else {
			sender = chat
		}
	} else {
		sender, err = types.ParseJID(targetSenderJID)
		if err != nil {
			return "", fmt.Errorf("parse sender: %w", err)
		}
	}
	msg := c.wa.BuildReaction(chat, sender, targetMsgID, emoji)
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send reaction: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// MarkRead sends a read receipt for the given message ids. `senderJID`
// is the original message sender (the participant in groups; the chat
// peer in 1:1). `msgIDsJSON` is a JSON array of message id strings.
//
// whatsmeow's Client.MarkRead defaults to ReceiptTypeRead when no extra
// type is passed, which is what we want for blue-tick semantics.
func (c *Client) MarkRead(chatJID, senderJID, msgIDsJSON string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	sender, err := types.ParseJID(senderJID)
	if err != nil {
		return fmt.Errorf("parse sender: %w", err)
	}
	var idStrings []string
	if err := json.Unmarshal([]byte(msgIDsJSON), &idStrings); err != nil {
		return fmt.Errorf("parse ids: %w", err)
	}
	if len(idStrings) == 0 {
		return nil
	}
	ids := make([]types.MessageID, 0, len(idStrings))
	for _, s := range idStrings {
		ids = append(ids, types.MessageID(s))
	}
	return c.wa.MarkRead(context.Background(), ids, time.Now(), chat, sender)
}

// SendText sends a plain-text message. Returns JSON of JSendResult.
func (c *Client) SendText(chatJID, body string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return "", fmt.Errorf("parse jid: %q is not a valid jid", chatJID)
	}
	msg := &waE2E.Message{Conversation: proto.String(body)}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{
		MessageID: resp.ID,
		Timestamp: resp.Timestamp.Unix(),
	})
	return string(out), nil
}

// dispatchMessage converts whatsmeow Message events to JMessage JSON.
func (c *Client) dispatchMessage(evt *events.Message) {
	if r := evt.Message.GetReactionMessage(); r != nil {
		c.dispatchReaction(
			evt.Info.Chat.String(),
			evt.Info.Sender.String(),
			evt.Info.Timestamp.Unix(),
			r,
		)
		return
	}
	// Community-announcement groups wrap reactions in EncReactionMessage
	// rather than the plain ReactionMessage. Decrypt and dispatch through
	// the same path so the UI is uniform. See docs/TODO.md "Reactions:
	// Community-announcement encrypted reactions need explicit
	// DecryptReaction".
	if evt.Message.GetEncReactionMessage() != nil {
		decrypted, err := c.wa.DecryptReaction(context.Background(), evt)
		if err == nil && decrypted != nil {
			c.dispatchReaction(
				evt.Info.Chat.String(),
				evt.Info.Sender.String(),
				evt.Info.Timestamp.Unix(),
				decrypted,
			)
		} else {
			fmt.Fprintf(os.Stderr,
				"[yawac/enc-reaction] decrypt fail chat=%s sender=%s err=%v\n",
				evt.Info.Chat.String(), evt.Info.Sender.String(), err)
		}
		return
	}
	// Edits and revokes arrive as ProtocolMessage wrappers; route them to
	// dedicated Swift events rather than a generic "Message" bubble.
	if pm := evt.Message.GetProtocolMessage(); pm != nil {
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			key := pm.GetKey()
			if key == nil {
				return
			}
			b, _ := json.Marshal(JMessageRevoked{
				ChatJID:   evt.Info.Chat.String(),
				MessageID: key.GetID(),
				RevokedBy: evt.Info.Sender.String(),
				Timestamp: evt.Info.Timestamp.Unix(),
			})
			c.dispatch("MessageRevoked", string(b))
			return
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			key := pm.GetKey()
			if key == nil {
				return
			}
			b, _ := json.Marshal(JMessageEdited{
				ChatJID:   evt.Info.Chat.String(),
				MessageID: key.GetID(),
				NewText:   extractText(pm.GetEditedMessage()),
				Timestamp: evt.Info.Timestamp.Unix(),
			})
			c.dispatch("MessageEdited", string(b))
			return
		}
	}
	// Poll updates (votes) are not displayed as chat entries — they
	// become tally updates on the original poll bubble.
	if evt.Message.GetPollUpdateMessage() != nil {
		c.dispatchPollVote(evt)
		return
	}
	jm := JMessage{
		ID:             evt.Info.ID,
		ChatJID:        evt.Info.Chat.String(),
		SenderJID:      evt.Info.Sender.String(),
		SenderPushName: evt.Info.PushName,
		FromMe:         evt.Info.IsFromMe,
		Timestamp:      evt.Info.Timestamp.Unix(),
		Kind:           classifyMessage(evt.Message),
	}
	switch {
	case evt.Message.GetConversation() != "":
		jm.Text = evt.Message.GetConversation()
	case evt.Message.GetExtendedTextMessage() != nil:
		jm.Text = evt.Message.GetExtendedTextMessage().GetText()
	}
	if m := evt.Message.GetImageMessage(); m != nil {
		jm.Media = mediaFromImage(m)
	} else if m := evt.Message.GetVideoMessage(); m != nil {
		jm.Media = mediaFromVideo(m)
	} else if m := evt.Message.GetAudioMessage(); m != nil {
		jm.Media = mediaFromAudio(m)
	} else if m := evt.Message.GetDocumentMessage(); m != nil {
		jm.Media = mediaFromDocument(m)
	} else if m := evt.Message.GetStickerMessage(); m != nil {
		jm.Media = mediaFromSticker(m)
	}
	if p := extractPoll(evt.Message); p != nil {
		jm.Poll = p
	}
	b, _ := json.Marshal(jm)
	c.dispatch("Message", string(b))
}

func classifyMessage(m *waE2E.Message) string {
	switch {
	case m.GetConversation() != "":
		return "text"
	case m.GetExtendedTextMessage() != nil:
		return "text"
	case m.GetImageMessage() != nil:
		return "image"
	case m.GetVideoMessage() != nil:
		return "video"
	case m.GetAudioMessage() != nil:
		return "audio"
	case m.GetDocumentMessage() != nil:
		return "document"
	case m.GetStickerMessage() != nil:
		return "sticker"
	case m.GetLocationMessage() != nil:
		return "location"
	case m.GetReactionMessage() != nil:
		return "reaction"
	case isPollCreation(m):
		return "poll"
	case m.GetPollUpdateMessage() != nil:
		return "poll_vote"
	case m.GetProtocolMessage() != nil:
		return "protocol"
	default:
		return "system"
	}
}

// extractText returns the plain text body of a message, covering the two
// common cases: Conversation (plain 1:1 text) and ExtendedTextMessage (links,
// quotes). Used by the MESSAGE_EDIT handler to surface the edited body.
func extractText(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	if t := m.GetConversation(); t != "" {
		return t
	}
	if e := m.GetExtendedTextMessage(); e != nil {
		return e.GetText()
	}
	return ""
}

func mediaFromImage(m *waE2E.ImageMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Caption:   m.GetCaption(),
		Width:     int(m.GetWidth()),
		Height:    int(m.GetHeight()),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "image",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

func mediaFromVideo(m *waE2E.VideoMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Caption:   m.GetCaption(),
		Width:     int(m.GetWidth()),
		Height:    int(m.GetHeight()),
		Duration:  int(m.GetSeconds()),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "video",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

func mediaFromAudio(m *waE2E.AudioMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Duration:  int(m.GetSeconds()),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "audio",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

func mediaFromDocument(m *waE2E.DocumentMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Caption:   m.GetCaption(),
		FileName:  m.GetFileName(),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "document",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

// dispatchReaction emits a "Reaction" event for both live messages
// (whatsmeow events.Message with ReactionMessage) and history-sync
// WebMessageInfo records. Reactions are NOT delivered as "Message"
// events — Swift treats them as bubble adornments, not chat entries.
func (c *Client) dispatchReaction(chatJID, senderJID string, ts int64, r *waE2E.ReactionMessage) {
	key := r.GetKey()
	if key == nil {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/reaction] dispatch chat=%s sender=%s target=%s emoji=%q\n",
		chatJID, senderJID, key.GetID(), r.GetText())
	payload := JReaction{
		ChatJID:         chatJID,
		TargetMessageID: key.GetID(),
		TargetFromMe:    key.GetFromMe(),
		SenderJID:       senderJID,
		Emoji:           r.GetText(),
		Timestamp:       ts,
	}
	b, _ := json.Marshal(payload)
	c.dispatch("Reaction", string(b))
}

func mediaFromSticker(m *waE2E.StickerMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "sticker",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

// SendTextReply sends a text message that quotes another message.
// quotedKind is one of text/image/video/audio/document/sticker.
// quotedSnippet is what other clients will render if they cannot
// resolve the stanza-id back to the original.
func (c *Client) SendTextReply(
	chatJID, body string,
	quotedID, quotedSenderJID string,
	quotedFromMe bool,
	quotedKind, quotedSnippet string,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	senderForCtx := quotedSenderJID
	if quotedFromMe {
		if c.wa.Store != nil && c.wa.Store.ID != nil {
			senderForCtx = c.wa.Store.ID.ToNonAD().String()
		}
	} else {
		if _, err := types.ParseJID(quotedSenderJID); err != nil {
			return "", fmt.Errorf("parse quoted sender: %w", err)
		}
	}
	ctx := &waE2E.ContextInfo{
		StanzaID:      proto.String(quotedID),
		Participant:   proto.String(senderForCtx),
		QuotedMessage: stubQuoted(quotedKind, quotedSnippet),
	}
	msg := &waE2E.Message{
		ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        proto.String(body),
			ContextInfo: ctx,
		},
	}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

func stubQuoted(kind, snippet string) *waE2E.Message {
	switch kind {
	case "image":
		return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String(snippet)}}
	case "video":
		return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{Caption: proto.String(snippet)}}
	case "audio":
		return &waE2E.Message{AudioMessage: &waE2E.AudioMessage{}}
	case "document":
		return &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: proto.String(snippet)}}
	case "sticker":
		return &waE2E.Message{StickerMessage: &waE2E.StickerMessage{}}
	default: // "text" and unknown kinds
		return &waE2E.Message{Conversation: proto.String(snippet)}
	}
}
