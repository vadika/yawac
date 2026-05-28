package bridge

import (
	"strings"
	"testing"
)

func TestSetBlockedBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/b.db")
	defer c.Close()
	err := c.SetBlocked("abc:def@x", true)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestListBlockedUnconnectedErrors(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/b2.db")
	defer c.Close()
	// Not connected → GetBlocklist's IQ cannot complete; expect an error
	// rather than a bogus empty success.
	if _, err := c.ListBlocked(); err == nil {
		t.Fatal("want error from unconnected ListBlocked")
	}
}
