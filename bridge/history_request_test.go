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
