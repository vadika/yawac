package bridge

import (
	"encoding/json"
	"testing"
	"time"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waHistoryPb "go.mau.fi/whatsmeow/proto/waHistorySync"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func TestApplyHistorySyncEmitsMessages(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/h2.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)

	syncType := waHistoryPb.HistorySync_FULL
	msgID := "ABCDEF"
	chatJID := "12345@s.whatsapp.net"
	fromMe := false
	ts := uint64(1234)

	wm := &waWeb.WebMessageInfo{
		Key: &waCommon.MessageKey{
			ID:        proto.String(msgID),
			FromMe:    proto.Bool(fromMe),
			RemoteJID: proto.String(chatJID),
		},
		MessageTimestamp: proto.Uint64(ts),
		Message: &waE2E.Message{
			Conversation: proto.String("hello from history"),
		},
	}
	conv := &waHistoryPb.Conversation{
		ID:       proto.String(chatJID),
		Name:     proto.String("Test Person"),
		Messages: []*waHistoryPb.HistorySyncMsg{{Message: wm}},
	}
	pname := &waHistoryPb.Pushname{
		ID:       proto.String(chatJID),
		Pushname: proto.String("Test Person Push"),
	}
	h := &events.HistorySync{Data: &waHistoryPb.HistorySync{
		SyncType:      &syncType,
		Conversations: []*waHistoryPb.Conversation{conv},
		Pushnames:     []*waHistoryPb.Pushname{pname},
	}}
	c.dispatchHistory(h)

	e := sink.wait(t, "Message", time.Second)
	var jm JMessage
	if err := json.Unmarshal([]byte(e.payload), &jm); err != nil {
		t.Fatal(err)
	}
	if jm.ID != msgID || jm.Text != "hello from history" {
		t.Fatalf("bad message: %+v", jm)
	}
	if jm.ChatJID != chatJID {
		t.Fatalf("bad chat jid: %q", jm.ChatJID)
	}
	if jm.Kind != "text" {
		t.Fatalf("bad kind: %q", jm.Kind)
	}
	if jm.Timestamp != int64(ts) {
		t.Fatalf("bad ts: %d", jm.Timestamp)
	}

	e2 := sink.wait(t, "HistorySync", time.Second)
	var m map[string]any
	if err := json.Unmarshal([]byte(e2.payload), &m); err != nil {
		t.Fatal(err)
	}
	if cv, ok := m["conversations"].(float64); !ok || int(cv) != 1 {
		t.Fatalf("bad conversations count: %v", m["conversations"])
	}
}
