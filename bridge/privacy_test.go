package bridge

import (
	"strings"
	"testing"
)

// GetPrivacySettings against an unpaired client returns whatever
// whatsmeow's cache has (typically empty defaults) — but our bridge
// wrapper still guards against a nil whatsmeow handle. Close the
// client first to force the nil branch.
func TestGetPrivacySettingsClosed(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pg.db")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	c.Close()
	c.wa = nil
	_, err = c.GetPrivacySettings()
	if err == nil || !strings.Contains(err.Error(), "client closed") {
		t.Fatalf("want client closed, got %v", err)
	}
}

func TestSetPrivacySettingClosed(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/ps.db")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	c.Close()
	c.wa = nil
	err = c.SetPrivacySetting("last", "all")
	if err == nil || !strings.Contains(err.Error(), "client closed") {
		t.Fatalf("want client closed, got %v", err)
	}
}

// SetPrivacySetting must reject empty inputs before reaching the
// underlying IQ send (which would otherwise wait on a socket).
func TestSetPrivacySettingEmptyArgs(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pe.db")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close()

	if err := c.SetPrivacySetting("", "all"); err == nil ||
		!strings.Contains(err.Error(), "empty name or value") {
		t.Fatalf("want empty name error, got %v", err)
	}
	if err := c.SetPrivacySetting("last", ""); err == nil ||
		!strings.Contains(err.Error(), "empty name or value") {
		t.Fatalf("want empty value error, got %v", err)
	}
}
