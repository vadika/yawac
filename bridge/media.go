package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"go.mau.fi/whatsmeow"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// SendImage reads a local file, uploads it to WhatsApp, and sends an
// ImageMessage to the given chat. Returns JSON of JSendResult.
func (c *Client) SendImage(chatJID, filePath, caption string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	up, err := c.wa.Upload(context.Background(), data, whatsmeow.MediaImage)
	if err != nil {
		return "", fmt.Errorf("upload: %w", err)
	}

	msg := &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
		Caption:       proto.String(caption),
		URL:           &up.URL,
		DirectPath:    &up.DirectPath,
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String("image/jpeg"),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(uint64(len(data))),
	}}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send image: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}
