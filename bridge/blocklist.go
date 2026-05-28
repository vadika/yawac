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
//
// WhatsApp's blocklist set requires the LID form for users that have a LID
// (post privacy-migration); sending the phone JID returns "400 bad-request".
// So when given a phone JID we resolve it to its LID first. Contacts with no
// known LID mapping fall back to the phone JID.
func (c *Client) SetBlocked(jid string, blocked bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	target, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	if target.Server == types.DefaultUserServer &&
		c.wa.Store != nil && c.wa.Store.LIDs != nil {
		if lid, lerr := c.wa.Store.LIDs.GetLIDForPN(context.Background(), target); lerr == nil && !lid.IsEmpty() {
			target = lid
		}
	}
	action := events.BlocklistChangeActionUnblock
	if blocked {
		action = events.BlocklistChangeActionBlock
	}
	_, err = c.wa.UpdateBlocklist(context.Background(), target, action)
	return err
}

// ListBlocked returns a JSON array of blocked JID strings (GetBlocklist).
// The server stores blocks by LID; we normalize each entry back to its phone
// JID when a mapping is known so the result matches the phone-keyed chats the
// Swift side holds (drives the blocked banner + name resolution). Entries with
// no known PN mapping are returned in their original (LID) form.
func (c *Client) ListBlocked() (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	list, err := c.wa.GetBlocklist(context.Background())
	if err != nil {
		return "", fmt.Errorf("get blocklist: %w", err)
	}
	ctx := context.Background()
	out := make([]string, 0, len(list.JIDs))
	for _, j := range list.JIDs {
		if j.Server == types.HiddenUserServer &&
			c.wa.Store != nil && c.wa.Store.LIDs != nil {
			if pn, perr := c.wa.Store.LIDs.GetPNForLID(ctx, j); perr == nil && !pn.IsEmpty() {
				out = append(out, pn.String())
				continue
			}
		}
		out = append(out, j.String())
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
