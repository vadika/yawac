package bridge

import (
	"strings"
	"testing"
)

func TestFetchProfilePictureBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/av.db")
	defer c.Close()
	_, err := c.FetchProfilePicture("nope", "/tmp/x.jpg")
	if err == nil || !strings.Contains(err.Error(), "parse jid") {
		t.Fatalf("want parse jid, got %v", err)
	}
}
