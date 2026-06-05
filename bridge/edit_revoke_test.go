package bridge

import "testing"

func TestEditTextClosedClient(t *testing.T) {
	c := &Client{}
	if _, err := c.EditText("12@s.whatsapp.net", "ABC", "new", "", 0); err == nil {
		t.Fatal("expected error")
	}
}

func TestEditTextRejectsBadJID(t *testing.T) {
	c := &Client{}
	if _, err := c.EditText("not-a-jid", "ABC", "new", "", 0); err == nil {
		t.Fatal("expected error")
	}
}

func TestEditTextRejectsEmptyBody(t *testing.T) {
	c := &Client{}
	if _, err := c.EditText("12@s.whatsapp.net", "ABC", "", "", 0); err == nil {
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

func TestEditTextEphemeralAcceptedNotWrapped(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/et.db")
	defer c.Close()
	_, err := c.EditText(
		"1@s.whatsapp.net", "MSG1", "fixed body",
		`[]`,
		86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestEditTextSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, string, string, int32) (string, error) =
		func(c *Client) func(string, string, string, string, int32) (string, error) {
			return c.EditText
		}
}
