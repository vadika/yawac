package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

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
	case m.GetProtocolMessage() != nil:
		return "protocol"
	default:
		return "system"
	}
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
