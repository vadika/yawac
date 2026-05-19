package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
