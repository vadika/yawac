package bridge

import (
	"encoding/json"
	"strings"
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
		var got JPhoneCheck
		if jerr := json.Unmarshal([]byte(s), &got); jerr != nil {
			t.Fatalf("decode: %v (%s)", jerr, s)
		}
	}
}

func TestJPhoneCheckNewFieldsDecode(t *testing.T) {
	payload := `{"jid":"49123@s.whatsapp.net","registered":true,"business_name":"Acme","push_name":"Alice","full_name":"Alice Smith"}`
	var got JPhoneCheck
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.JID != "49123@s.whatsapp.net" {
		t.Errorf("JID: got %q", got.JID)
	}
	if !got.Registered {
		t.Error("Registered: expected true")
	}
	if got.BusinessName != "Acme" {
		t.Errorf("BusinessName: got %q", got.BusinessName)
	}
	if got.PushName != "Alice" {
		t.Errorf("PushName: got %q", got.PushName)
	}
	if got.FullName != "Alice Smith" {
		t.Errorf("FullName: got %q", got.FullName)
	}
}

func TestJPhoneCheckOmitsEmptyOptionalFields(t *testing.T) {
	// omitempty: push_name and full_name absent from JSON when empty
	check := JPhoneCheck{JID: "1@s.whatsapp.net", Registered: true}
	b, err := json.Marshal(check)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	if strings.Contains(s, "push_name") || strings.Contains(s, "full_name") {
		t.Errorf("expected omitempty fields absent, got: %s", s)
	}
}

func TestCheckOnWhatsAppRejectsEmpty(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	if _, err := c.CheckOnWhatsApp(""); err == nil {
		t.Fatalf("expected error on empty phone")
	}
}
