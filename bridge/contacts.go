package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
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

// JPhoneCheck is the JSON-friendly view of an IsOnWhatsApp lookup result.
type JPhoneCheck struct {
	JID          string `json:"jid"`
	Registered   bool   `json:"registered"`
	BusinessName string `json:"business_name,omitempty"`
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
		// whatsmeow surfaces server rate-limit (429) via an error whose
		// message contains "rate-overlimit"; normalize so Swift can branch.
		if strings.Contains(err.Error(), "rate") {
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
	b, _ := json.Marshal(out)
	return string(b), nil
}
