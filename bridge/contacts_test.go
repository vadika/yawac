package bridge

import (
	"encoding/json"
	"testing"
)

func TestListContactsReturnsArray(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	s, err := c.ListContacts()
	if err != nil {
		t.Skipf("ListContacts on unpaired client: %v", err)
	}
	var arr []JContact
	if err := json.Unmarshal([]byte(s), &arr); err != nil {
		t.Fatalf("decode: %v (%s)", err, s)
	}
}

func TestCheckOnWhatsAppUnpaired(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/c.db")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close()
	// Unpaired client cannot reach the server; we only assert that the
	// method exists, returns a non-nil error or a decodable JSON shape,
	// and never panics.
	s, err := c.CheckOnWhatsApp("4915123456789")
	if err == nil {
		var got struct {
			JID          string `json:"jid"`
			Registered   bool   `json:"registered"`
			BusinessName string `json:"business_name,omitempty"`
		}
		if jerr := json.Unmarshal([]byte(s), &got); jerr != nil {
			t.Fatalf("decode: %v (%s)", jerr, s)
		}
	}
}

func TestCheckOnWhatsAppRejectsEmpty(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	if _, err := c.CheckOnWhatsApp(""); err == nil {
		t.Fatalf("expected error on empty phone")
	}
}
