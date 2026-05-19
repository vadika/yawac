package bridge

import (
	"strings"
	"testing"
)

func TestSendTypingBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/pr.db")
	defer c.Close()
	err := c.SendTyping("nope", true)
	if err == nil || !strings.Contains(err.Error(), "parse jid") {
		t.Fatalf("got %v", err)
	}
}
