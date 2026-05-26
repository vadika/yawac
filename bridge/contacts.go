package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

// JContact is the JSON-friendly view of a WhatsApp contact.
type JContact struct {
	JID          string `json:"jid"`
	Name         string `json:"name"`
	PushName     string `json:"push_name,omitempty"`
	FullName     string `json:"full_name,omitempty"`
	BusinessName string `json:"business_name,omitempty"`
}

// ListContacts returns JSON array of known contacts from the local store.
// Only contacts with at least one non-empty display name field are included.
func (c *Client) ListContacts() (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if c.wa.Store == nil || c.wa.Store.Contacts == nil {
		return "", errors.New("contact store unavailable")
	}
	contacts, err := c.wa.Store.Contacts.GetAllContacts(context.Background())
	if err != nil {
		return "", fmt.Errorf("get contacts: %w", err)
	}
	out := make([]JContact, 0, len(contacts))
	for jid, info := range contacts {
		name := info.FullName
		if name == "" {
			name = info.PushName
		}
		if name == "" {
			name = info.BusinessName
		}
		if name == "" {
			continue // skip nameless entries
		}
		out = append(out, JContact{
			JID:          jid.String(),
			Name:         name,
			PushName:     info.PushName,
			FullName:     info.FullName,
			BusinessName: info.BusinessName,
		})
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// JUserInfo is the JSON-friendly view of a usync user-info lookup.
// Status is the "About" text shown in the user profile (e.g. "Free to chat").
type JUserInfo struct {
	JID    string `json:"jid"`
	Status string `json:"status,omitempty"`
}

// GetUserInfo queries the server for `jid`'s public profile fields
// (status / About text). Result is a JSON-encoded JUserInfo. Returns
// an empty Status string when the server returns no <status> child or
// when the user has not set an About text.
func (c *Client) GetUserInfo(jidStr string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	resp, err := c.wa.GetUserInfo(context.Background(), []types.JID{jid})
	if err != nil {
		return "", fmt.Errorf("get user info: %w", err)
	}
	out := JUserInfo{JID: jidStr}
	if info, ok := resp[jid]; ok {
		out.Status = info.Status
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// JPhoneCheck is the JSON-friendly view of an IsOnWhatsApp lookup result.
type JPhoneCheck struct {
	JID          string `json:"jid"`
	Registered   bool   `json:"registered"`
	BusinessName string `json:"business_name,omitempty"`
	PushName     string `json:"push_name,omitempty"`
	FullName     string `json:"full_name,omitempty"`
}

// CheckOnWhatsApp asks the WhatsApp server whether `phone` (E.164 digits,
// no `+`) is registered. Returns a JSON string of JPhoneCheck.
// Errors: `"rate_limited"` when the server responds with the rate-limit
// code; bridge / network errors are wrapped verbatim.
func (c *Client) CheckOnWhatsApp(phone string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if phone == "" {
		return "", errors.New("empty phone")
	}
	resp, err := c.wa.IsOnWhatsApp(context.Background(), []string{phone})
	if err != nil {
		if errors.Is(err, whatsmeow.ErrIQRateOverLimit) {
			return "", errors.New("rate_limited")
		}
		return "", fmt.Errorf("is_on_whatsapp: %w", err)
	}
	if len(resp) == 0 {
		// Server accepted the query but returned nothing — treat as
		// "not registered" rather than an error.
		b, _ := json.Marshal(JPhoneCheck{Registered: false})
		return string(b), nil
	}
	r := resp[0]
	out := JPhoneCheck{
		JID:        r.JID.String(),
		Registered: r.IsIn,
	}
	if r.VerifiedName != nil {
		out.BusinessName = r.VerifiedName.Details.GetVerifiedName()
	}
	if r.IsIn && c.wa.Store != nil && c.wa.Store.Contacts != nil {
		if ci, err := c.wa.Store.Contacts.GetContact(context.Background(), r.JID); err == nil && ci.Found {
			out.PushName = ci.PushName
			out.FullName = ci.FullName
			if out.BusinessName == "" {
				out.BusinessName = ci.BusinessName
			}
		}
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
