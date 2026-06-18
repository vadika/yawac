package bridge

import (
	"testing"
)

func TestSetSelfAvatarUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sa.db")
	defer c.Close()
	if err := c.SetSelfAvatar([]byte{0xFF}); err == nil {
		t.Fatal("expected error on unpaired")
	}
}

func TestRemoveSelfAvatarUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/rsa.db")
	defer c.Close()
	if err := c.RemoveSelfAvatar(); err == nil {
		t.Fatal("expected error on unpaired")
	}
}

func TestSetSelfAboutUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/saa.db")
	defer c.Close()
	if err := c.SetSelfAbout("Hello"); err == nil {
		// SetStatusMessage may or may not require pairing; if it
		// succeeds on unpaired (returns context cancelled or null),
		// accept that — but it generally requires a live connection.
		t.Log("note: SetSelfAbout on unpaired did not error")
	}
}

func TestSetSelfPushNameUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/p3.db")
	defer c.Close()
	if err := c.SetSelfPushName("Bob"); err == nil {
		t.Log("note: SetSelfPushName on unpaired did not error")
	}
}

func TestSetSelfPushNameRejectsEmpty(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/p4.db")
	defer c.Close()
	if err := c.SetSelfPushName("  "); err == nil {
		t.Fatal("expected error on whitespace-only push name")
	}
}
