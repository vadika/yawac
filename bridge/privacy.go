package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
)

// JPrivacySettings is the JSON shape returned by GetPrivacySettings.
// Mirrored on the Swift side as BridgePrivacySettings. Only the five
// knobs surfaced in the v0.9.12 Privacy sheet are exposed — Online,
// CallAdd, Messages, Defense, and Stickers are intentionally omitted
// (Online is redundant with LastSeen for v1; the rest have niche
// allowed-value tables that don't fit the three-way picker UI).
//
// Each value is the wire string from whatsmeow: "all", "contacts",
// "contact_blacklist", or "none" for the four visibility knobs, and
// "all" / "none" for ReadReceipts.
type JPrivacySettings struct {
	LastSeen     string `json:"last_seen"`
	Profile      string `json:"profile"`
	Status       string `json:"status"`
	ReadReceipts string `json:"read_receipts"`
	GroupAdd     string `json:"group_add"`
}

// GetPrivacySettings returns the paired account's current privacy
// settings as JSON. whatsmeow's underlying GetPrivacySettings logs
// fetch errors rather than returning them, so on first call against
// a freshly-connected client this may block briefly on an IQ round
// trip; subsequent calls are served from the in-memory cache.
func (c *Client) GetPrivacySettings() (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	s := c.wa.GetPrivacySettings(context.Background())
	out := JPrivacySettings{
		LastSeen:     string(s.LastSeen),
		Profile:      string(s.Profile),
		Status:       string(s.Status),
		ReadReceipts: string(s.ReadReceipts),
		GroupAdd:     string(s.GroupAdd),
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// SetPrivacySetting updates one privacy knob. `name` must be one of:
// "last", "profile", "status", "readreceipts", "groupadd" — the wire
// PrivacySettingType strings from whatsmeow.
// `value` must be one of: "all", "contacts", "contact_blacklist",
// "none". ReadReceipts only accepts "all" / "none" — whatsmeow will
// reject "contacts" server-side, so the caller is responsible for
// not offering it.
func (c *Client) SetPrivacySetting(name, value string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if name == "" || value == "" {
		return fmt.Errorf("empty name or value")
	}
	_, err := c.wa.SetPrivacySetting(context.Background(),
		types.PrivacySettingType(name),
		types.PrivacySetting(value))
	if err != nil {
		return fmt.Errorf("set privacy %s=%s: %w", name, value, err)
	}
	return nil
}
