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
//
// EditText edits a previously-sent text message. The ephemeralSec
// parameter is accepted for signature parity with the other five
// threaded sends but is intentionally NOT wrapped via wrapForChat:
// WhatsApp protocol convention is that edits inherit the original
// message's expiration timer, so an additional EphemeralMessage
// wrap is unnecessary (and may be rejected by the server). The
// parameter is reserved for a future protocol-level change.
func (c *Client) EditText(
	chatJID, msgID, newBody, mentionedJIDsJSON string,
	ephemeralSec int32,
) (string, error) {
	_ = ephemeralSec // intentional: see doc comment above
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
	var mentionedJIDs []string
	if mentionedJIDsJSON != "" {
		if err := json.Unmarshal([]byte(mentionedJIDsJSON), &mentionedJIDs); err != nil {
			return "", fmt.Errorf("parse mentionedJIDs: %w", err)
		}
	}
	var newMsg *waE2E.Message
	if len(mentionedJIDs) == 0 {
		newMsg = &waE2E.Message{Conversation: proto.String(newBody)}
	} else {
		newMsg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        proto.String(newBody),
			ContextInfo: &waE2E.ContextInfo{MentionedJID: mentionedJIDs},
		}}
	}
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
