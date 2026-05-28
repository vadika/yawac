package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// SetBlocked blocks or unblocks a user via the WhatsApp blocklist IQ
// (UpdateBlocklist). The change propagates to the user's other devices.
func (c *Client) SetBlocked(jid string, blocked bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	target, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	action := events.BlocklistChangeActionUnblock
	if blocked {
		action = events.BlocklistChangeActionBlock
	}
	_, err = c.wa.UpdateBlocklist(context.Background(), target, action)
	return err
}

// ListBlocked returns a JSON array of the JID strings the user has blocked,
// fetched from the server (GetBlocklist).
func (c *Client) ListBlocked() (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	list, err := c.wa.GetBlocklist(context.Background())
	if err != nil {
		return "", fmt.Errorf("get blocklist: %w", err)
	}
	out := make([]string, 0, len(list.JIDs))
	for _, j := range list.JIDs {
		out = append(out, j.String())
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
