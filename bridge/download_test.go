package bridge

import (
	"strings"
	"testing"
)

func TestDownloadMediaBadJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/d.db")
	defer c.Close()
	_, err := c.DownloadMedia("not json", "/tmp/out.bin")
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("want parse err, got %v", err)
	}
}
