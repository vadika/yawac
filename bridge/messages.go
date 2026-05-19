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
	jm := JMessage{
		ID:        evt.Info.ID,
		ChatJID:   evt.Info.Chat.String(),
		SenderJID: evt.Info.Sender.String(),
		FromMe:    evt.Info.IsFromMe,
		Timestamp: evt.Info.Timestamp.Unix(),
		Kind:      classifyMessage(evt.Message),
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
	return &JMedia{MimeType: m.GetMimetype(), Caption: m.GetCaption(),
		Width: int(m.GetWidth()), Height: int(m.GetHeight()),
		SizeBytes: int64(m.GetFileLength())}
}

func mediaFromVideo(m *waE2E.VideoMessage) *JMedia {
	return &JMedia{MimeType: m.GetMimetype(), Caption: m.GetCaption(),
		Width: int(m.GetWidth()), Height: int(m.GetHeight()),
		Duration: int(m.GetSeconds()), SizeBytes: int64(m.GetFileLength())}
}

func mediaFromAudio(m *waE2E.AudioMessage) *JMedia {
	return &JMedia{MimeType: m.GetMimetype(),
		Duration: int(m.GetSeconds()), SizeBytes: int64(m.GetFileLength())}
}

func mediaFromDocument(m *waE2E.DocumentMessage) *JMedia {
	return &JMedia{MimeType: m.GetMimetype(), Caption: m.GetCaption(),
		SizeBytes: int64(m.GetFileLength())}
}

func mediaFromSticker(m *waE2E.StickerMessage) *JMedia {
	return &JMedia{MimeType: m.GetMimetype(), SizeBytes: int64(m.GetFileLength())}
}
