package bridge

import (
	"encoding/json"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func TestReceiptJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/r.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("12345@s.whatsapp.net")
	sender, _ := types.ParseJID("67890@s.whatsapp.net")
	c.dispatchReceipt(&events.Receipt{
		MessageSource: types.MessageSource{Chat: chat, Sender: sender},
		MessageIDs:    []string{"M1", "M2"},
		Type:          types.ReceiptTypeRead,
		Timestamp:     time.Unix(42, 0),
	})
	e := sink.wait(t, "Receipt", time.Second)
	var jr JReceipt
	if err := json.Unmarshal([]byte(e.payload), &jr); err != nil {
		t.Fatal(err)
	}
	if jr.Status != "read" || len(jr.MessageIDs) != 2 || jr.Timestamp != 42 {
		t.Fatalf("bad receipt: %+v", jr)
	}
}
