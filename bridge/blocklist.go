package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/types"
)

// SetBlocked blocks or unblocks a user.
//
// WhatsApp migrated the blocklist to LID addressing: the server stores each
// entry as <item jid="<lid>@lid" pn_jid="<phone>@s.whatsapp.net"/> and rejects
// a set request that carries only one of the two forms ("400 bad-request",
// addressing_mode="lid"). whatsmeow's UpdateBlocklist sends only `jid`, so it
// can't satisfy this. We build the dual-addressed IQ ourselves and send it via
// the raw node API. The server pushes a blocklist notification on success,
// which whatsmeow turns into events.Blocklist → the Swift side re-fetches.
func (c *Client) SetBlocked(jid string, blocked bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	target, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	ctx := context.Background()

	// Resolve both addressing forms from whichever one we were given.
	var lid, pn types.JID
	switch target.Server {
	case types.HiddenUserServer:
		lid = target
		if c.wa.Store != nil && c.wa.Store.LIDs != nil {
			pn, _ = c.wa.Store.LIDs.GetPNForLID(ctx, target)
		}
	default:
		pn = target
		if c.wa.Store != nil && c.wa.Store.LIDs != nil {
			lid, _ = c.wa.Store.LIDs.GetLIDForPN(ctx, target)
		}
	}

	action := "unblock"
	if blocked {
		action = "block"
	}

	itemAttrs := waBinary.Attrs{"action": action}
	if !lid.IsEmpty() {
		itemAttrs["jid"] = lid
		if !pn.IsEmpty() {
			itemAttrs["pn_jid"] = pn
		}
	} else {
		// No known LID mapping — fall back to the phone JID alone. Older
		// (pre-LID) accounts still accept this; LID accounts will reject it,
		// but we have nothing better without a server usync.
		itemAttrs["jid"] = target
	}

	node := waBinary.Node{
		Tag: "iq",
		Attrs: waBinary.Attrs{
			"id":    c.wa.DangerousInternals().GenerateRequestID(),
			"to":    types.ServerJID,
			"type":  "set",
			"xmlns": "blocklist",
		},
		Content: []waBinary.Node{{Tag: "item", Attrs: itemAttrs}},
	}
	return c.wa.DangerousInternals().SendNode(ctx, node)
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
