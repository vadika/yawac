package bridge

import (
	"encoding/json"
	"testing"
	"time"

	waHistoryPb "go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types/events"
)

func TestDispatchHistoryEmpty(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/h.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)

	syncType := waHistoryPb.HistorySync_FULL
	h := &events.HistorySync{Data: &waHistoryPb.HistorySync{SyncType: &syncType}}
	c.dispatchHistory(h)

	e := sink.wait(t, "HistorySync", time.Second)
	var m map[string]any
	if err := json.Unmarshal([]byte(e.payload), &m); err != nil {
		t.Fatal(err)
	}
	if m["sync_type"] != "FULL" {
		t.Fatalf("want FULL, got %v", m["sync_type"])
	}
}
