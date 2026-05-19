package bridge

import (
	"strings"
	"testing"
)

func TestSendImageMissingFile(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/im.db")
	defer c.Close()
	_, err := c.SendImage("1@s.whatsapp.net", "/no/such/file.jpg", "caption")
	if err == nil || !strings.Contains(err.Error(), "read file") {
		t.Fatalf("want read file error, got %v", err)
	}
}
