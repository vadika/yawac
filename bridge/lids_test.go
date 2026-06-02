package bridge

import "testing"

func TestResolveLIDToPNUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/lp.db")
	defer c.Close()
	// Unpaired client has no LID store; expect empty + nil (no mapping known).
	out, err := c.ResolveLIDToPN("123@lid")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if out != "" {
		t.Fatalf("expected empty (no mapping), got %q", out)
	}
}

func TestResolveLIDToPNPassesThroughNonLID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/lp2.db")
	defer c.Close()
	// Non-LID JID should round-trip unchanged.
	out, err := c.ResolveLIDToPN("123@s.whatsapp.net")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if out != "123@s.whatsapp.net" {
		t.Fatalf("expected pass-through, got %q", out)
	}
}

func TestResolvePNToLIDUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/pl.db")
	defer c.Close()
	out, err := c.ResolvePNToLID("123@s.whatsapp.net")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if out != "" {
		t.Fatalf("expected empty (no mapping), got %q", out)
	}
}

func TestResolvePNToLIDPassesThroughNonPN(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/pl2.db")
	defer c.Close()
	out, err := c.ResolvePNToLID("123@lid")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if out != "123@lid" {
		t.Fatalf("expected pass-through, got %q", out)
	}
}
