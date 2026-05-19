package bridge

import (
	"encoding/json"
	"testing"
	"time"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestDispatchReaction(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/rx.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)

	r := &waE2E.ReactionMessage{
		Key: &waCommon.MessageKey{
			ID:        proto.String("MSG1"),
			FromMe:    proto.Bool(true),
			RemoteJID: proto.String("12345@s.whatsapp.net"),
		},
		Text: proto.String("👍"),
	}
	c.dispatchReaction("12345@s.whatsapp.net", "67890@s.whatsapp.net", 42, r)

	e := sink.wait(t, "Reaction", time.Second)
	var jr JReaction
	if err := json.Unmarshal([]byte(e.payload), &jr); err != nil {
		t.Fatal(err)
	}
	if jr.Emoji != "👍" || jr.TargetMessageID != "MSG1" || !jr.TargetFromMe {
		t.Fatalf("bad reaction: %+v", jr)
	}
	if jr.ChatJID != "12345@s.whatsapp.net" || jr.SenderJID != "67890@s.whatsapp.net" {
		t.Fatalf("bad jids: %+v", jr)
	}
	if jr.Timestamp != 42 {
		t.Fatalf("bad ts: %+v", jr)
	}
}
