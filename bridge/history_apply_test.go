package bridge

import (
	"encoding/json"
	"testing"
	"time"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waGroupHistory "go.mau.fi/whatsmeow/proto/waGroupHistory"
	waHistoryPb "go.mau.fi/whatsmeow/proto/waHistorySync"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
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
		ID:                    proto.String(chatJID),
		Name:                  proto.String("Test Person"),
		ConversationTimestamp: proto.Uint64(ts),
		Messages:              []*waHistoryPb.HistorySyncMsg{{Message: wm}},
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

	metadataEvent := sink.wait(t, "HistoryConversation", time.Second)
	var metadata JHistoryConversation
	if err := json.Unmarshal([]byte(metadataEvent.payload), &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata.ChatJID != chatJID || metadata.Name != "Test Person" || metadata.Timestamp != int64(ts) {
		t.Fatalf("bad history conversation metadata: %+v", metadata)
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

func TestDispatchGroupHistoryEmitsSharedMessages(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/group-history.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)

	chat := types.JID{User: "120363407507540222", Server: types.GroupServer}
	c.dispatchGroupHistory(&events.GroupHistory{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, IsGroup: true},
			ID:            "bundle-1",
		},
		Data: &waGroupHistory.GroupHistory{Messages: []*waWeb.WebMessageInfo{{
			Key: &waCommon.MessageKey{
				ID:          proto.String("shared-1"),
				RemoteJID:   proto.String(chat.String()),
				Participant: proto.String("12345@s.whatsapp.net"),
			},
			MessageTimestamp: proto.Uint64(1_788_422_400),
			Message:          &waE2E.Message{Conversation: proto.String("hello from shared history")},
		}}},
	})

	e := sink.wait(t, "Message", time.Second)
	var message JMessage
	if err := json.Unmarshal([]byte(e.payload), &message); err != nil {
		t.Fatal(err)
	}
	if message.ID != "shared-1" || message.ChatJID != chat.String() || message.Text != "hello from shared history" {
		t.Fatalf("bad shared group message: %+v", message)
	}
}

func TestLocationJSONKeepsEmptyRequiredStrings(t *testing.T) {
	payload, err := json.Marshal(JLocationPayload{Lat: 59.3, Lng: 24.6})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err = json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["name"]; !ok {
		t.Fatal("location JSON omitted required name")
	}
	if _, ok := decoded["address"]; !ok {
		t.Fatal("location JSON omitted required address")
	}
}
