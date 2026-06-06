package bridge

import (
	"strings"
	"testing"
)

// Unpaired clients have no Store.ID; ListLinkedDevices must refuse
// rather than fan out a websocket-bound IQ. The full happy path needs
// a paired socket and is exercised on a real device.
func TestListLinkedDevicesUnpaired(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/dev.db")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close()
	_, err = c.ListLinkedDevices()
	if err == nil || !strings.Contains(err.Error(), "not paired") {
		t.Fatalf("want not paired, got %v", err)
	}
}
