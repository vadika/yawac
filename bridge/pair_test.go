package bridge

import (
	"testing"
	"time"
)

func TestConnectEmitsQRWhenUnpaired(t *testing.T) {
	if testing.Short() {
		t.Skip("network test")
	}
	c, err := NewClient(t.TempDir() + "/p.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	sink := newRecSink()
	c.SetEventSink(sink)

	if c.IsLoggedIn() {
		t.Fatal("fresh client should not be logged in")
	}
	if err := c.Connect(); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	e := sink.wait(t, "QR", 15*time.Second)
	if len(e.payload) < 5 {
		t.Fatalf("QR payload too short: %q", e.payload)
	}
}
