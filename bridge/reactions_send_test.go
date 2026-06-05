package bridge

import (
	"strings"
	"testing"
)

func TestSendReactionBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sr.db")
	defer c.Close()
	// "abc:def@x" — a JID literal that whatsmeow's ParseJID rejects (the
	// "def" device id is not a number). Confirms the parse-chat error path.
	_, err := c.SendReaction("abc:def@x", "MSG1", "12345@s.whatsapp.net", false, "👍", 0)
	if err == nil || !strings.Contains(err.Error(), "parse chat") {
		t.Fatalf("got %v", err)
	}
}

func TestSendReactionBadSenderJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sr.db")
	defer c.Close()
	// targetFromMe=false → sender JID is parsed. Same trick.
	_, err := c.SendReaction("12345@s.whatsapp.net", "MSG1", "abc:def@x", false, "👍", 0)
	if err == nil || !strings.Contains(err.Error(), "parse sender") {
		t.Fatalf("got %v", err)
	}
}
