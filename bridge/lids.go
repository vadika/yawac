package bridge

import (
	"context"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
)

// ResolveLIDToPN looks up the user's phone-number JID for a given @lid JID
// via whatsmeow's local store. Returns empty string with nil error when no
// mapping is known (the caller should keep the original JID in that case).
//
// Companion devices learn the LID↔PN mapping over time from group events
// and contact sync. Mappings that haven't been observed yet stay unknown.
func (c *Client) ResolveLIDToPN(lidJID string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(lidJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	// Non-LID JIDs round-trip unchanged regardless of Store state.
	if jid.Server != types.HiddenUserServer {
		return jid.String(), nil
	}
	if c.wa.Store == nil || c.wa.Store.LIDs == nil {
		return "", nil
	}
	pn, err := c.wa.Store.LIDs.GetPNForLID(context.Background(), jid)
	if err != nil {
		return "", fmt.Errorf("lookup: %w", err)
	}
	if pn.IsEmpty() {
		return "", nil
	}
	return pn.String(), nil
}

// ResolvePNToLID is the reverse of ResolveLIDToPN — returns the @lid form
// for a phone-number JID via whatsmeow's local store. Returns empty string
// with nil error when no mapping is known. Used by Swift-side identity
// equality so two contacts surfaced under different namespaces (address
// book PN + group participant LID) collapse to the same person.
func (c *Client) ResolvePNToLID(pnJID string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(pnJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	// Non-PN JIDs round-trip unchanged regardless of Store state.
	if jid.Server != types.DefaultUserServer {
		return jid.String(), nil
	}
	if c.wa.Store == nil || c.wa.Store.LIDs == nil {
		return "", nil
	}
	lid, err := c.wa.Store.LIDs.GetLIDForPN(context.Background(), jid)
	if err != nil {
		return "", fmt.Errorf("lookup: %w", err)
	}
	if lid.IsEmpty() {
		return "", nil
	}
	return lid.String(), nil
}
