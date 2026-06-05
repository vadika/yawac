package bridge

import (
	"strings"
	"testing"
)

func TestForwardTextBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardText("abc:def@x", "hi", 0)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestForwardMediaBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardMedia("abc:def@x", `{"kind":"image"}`, "", "", 0)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestForwardMediaBadRefJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardMedia("12345@s.whatsapp.net", "not json", "", "", 0)
	if err == nil || !strings.Contains(err.Error(), "parse ref") {
		t.Fatalf("got %v, want parse ref error", err)
	}
}

func TestForwardMediaUnknownKind(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/fw.db")
	defer c.Close()
	_, err := c.ForwardMedia("12345@s.whatsapp.net", `{"kind":"banana"}`, "", "", 0)
	if err == nil || !strings.Contains(err.Error(), "unsupported kind") {
		t.Fatalf("got %v, want unsupported kind error", err)
	}
}
