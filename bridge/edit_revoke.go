package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// EditText replaces the text of a previously-sent message. The
// 15-minute server window is NOT enforced here — the UI hides the
// menu item past 15 min and the server rejects late edits. Returns
// JSON of JSendResult carrying the edit envelope id (UI keeps the
// original msgID for display).
func (c *Client) EditText(chatJID, msgID, newBody string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if newBody == "" {
		return "", errors.New("empty body")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	newMsg := &waE2E.Message{Conversation: proto.String(newBody)}
	edit := c.wa.BuildEdit(chat, types.MessageID(msgID), newMsg)
	resp, err := c.wa.SendMessage(context.Background(), chat, edit)
	if err != nil {
		return "", fmt.Errorf("send edit: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// RevokeMessage sends a REVOKE protocol message. V1 supports only
// targetFromMe=true (revoking my own messages). Group-admin revoke
// of other users' messages is out of scope.
func (c *Client) RevokeMessage(
	chatJID, msgID, targetSenderJID string,
	targetFromMe bool,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if !targetFromMe {
		return "", errors.New("only own messages")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	var sender types.JID
	if c.wa.Store != nil && c.wa.Store.ID != nil {
		sender = c.wa.Store.ID.ToNonAD()
	} else {
		sender = chat
	}
	revoke := c.wa.BuildRevoke(chat, sender, types.MessageID(msgID))
	resp, err := c.wa.SendMessage(context.Background(), chat, revoke)
	if err != nil {
		return "", fmt.Errorf("send revoke: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}
