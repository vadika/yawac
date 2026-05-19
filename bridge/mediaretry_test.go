package bridge

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestRequestMediaRetryBadJSON(t *testing.T) {
	c, err := NewClient(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close()
	err = c.RequestMediaRetry("a@s.whatsapp.net", "b@s.whatsapp.net", "id", false, "not json")
	if err == nil || !strings.Contains(err.Error(), "parse ref") {
		t.Fatalf("got %v", err)
	}
}
