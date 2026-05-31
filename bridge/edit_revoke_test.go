package bridge

import "testing"

func TestEditTextClosedClient(t *testing.T) {
	c := &Client{}
	if _, err := c.EditText("12@s.whatsapp.net", "ABC", "new", ""); err == nil {
		t.Fatal("expected error")
	}
}

func TestEditTextRejectsBadJID(t *testing.T) {
	c := &Client{}
	if _, err := c.EditText("not-a-jid", "ABC", "new", ""); err == nil {
		t.Fatal("expected error")
	}
}

func TestEditTextRejectsEmptyBody(t *testing.T) {
	c := &Client{}
	if _, err := c.EditText("12@s.whatsapp.net", "ABC", "", ""); err == nil {
		t.Fatal("expected error for empty body")
	}
}

func TestRevokeMessageClosedClient(t *testing.T) {
	c := &Client{}
	if _, err := c.RevokeMessage("12@s.whatsapp.net", "ABC", "", true); err == nil {
		t.Fatal("expected error")
	}
}

func TestRevokeMessageRejectsPeerOwnedV1(t *testing.T) {
	c := &Client{}
	_, err := c.RevokeMessage("12@s.whatsapp.net", "ABC", "55@s.whatsapp.net", false)
	if err == nil {
		t.Fatal("expected error for non-own message in v1")
	}
}
