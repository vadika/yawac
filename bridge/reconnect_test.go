package bridge

import "testing"

func TestReconnectNoopWhenUnpaired(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/rc.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	// Fresh client has no Store.ID — Reconnect must return nil without
	// touching the socket (the QR/pair flow owns connect when unpaired).
	if err := c.Reconnect(); err != nil {
		t.Fatalf("Reconnect on unpaired client: got %v, want nil", err)
	}
	if c.IsConnected() {
		t.Fatal("fresh client should not report connected")
	}
}
