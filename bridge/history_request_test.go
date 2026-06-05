package bridge

import (
	"strings"
	"testing"
)

func TestRequestOlderHistoryBadChat(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/rh.db")
	defer c.Close()
	err := c.RequestOlderHistory("abc:def@x", "ID", "1@s.whatsapp.net", false, 0, 50)
	if err == nil || !strings.Contains(err.Error(), "parse chat") {
		t.Fatalf("got %v", err)
	}
}

func TestRequestFullHistorySyncUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/hr.db")
	defer c.Close()
	err := c.RequestFullHistorySync(
		"1@s.whatsapp.net", "MSG1", false, 1700000000, 100000)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestRequestFullHistorySyncBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/hr2.db")
	defer c.Close()
	err := c.RequestFullHistorySync(
		"not a jid", "MSG1", false, 1700000000, 100000)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestRequestFullHistorySyncSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, bool, int64, int32) error =
		func(c *Client) func(string, string, bool, int64, int32) error {
			return c.RequestFullHistorySync
		}
}
