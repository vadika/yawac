package bridge

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	proto "google.golang.org/protobuf/proto"
)

func TestSendTextRejectsBadJID(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/m.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.SendText("not-a-jid", "hi")
	if err == nil || !strings.Contains(err.Error(), "jid") {
		t.Fatalf("want jid error, got %v", err)
	}
}

func TestSendResultJSONShape(t *testing.T) {
	var r JSendResult
	if err := json.Unmarshal([]byte(`{"message_id":"abc","timestamp":1}`), &r); err != nil {
		t.Fatal(err)
	}
	if r.MessageID != "abc" || r.Timestamp != 1 {
		t.Fatal("decode mismatch")
	}
}

func TestSendTextReplyRejectsBadJID(t *testing.T) {
	c := &Client{}
	_, err := c.SendTextReply("not-a-jid", "hi",
		"ABCD1234", "12345@s.whatsapp.net", false,
		"text", "hello")
	if err == nil {
		t.Fatal("expected error for bad chat jid")
	}
}

func TestSendTextReplyClosedClient(t *testing.T) {
	c := &Client{} // wa is nil
	_, err := c.SendTextReply("12345@s.whatsapp.net", "hi",
		"ABCD1234", "12345@s.whatsapp.net", false,
		"text", "hello")
	if err == nil {
		t.Fatal("expected error for closed client")
	}
}

func TestDispatchRevokeEmitsMessageRevoked(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/rev.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("12345@s.whatsapp.net")
	sender, _ := types.ParseJID("67890@s.whatsapp.net")
	revokeKey := &waCommon.MessageKey{ID: proto.String("MSG-TO-REVOKE")}
	evt := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sender},
			ID:            "REVOKE-ENVELOPE",
			Timestamp:     time.Unix(1700000000, 0),
		},
		Message: &waE2E.Message{
			ProtocolMessage: &waE2E.ProtocolMessage{
				Type: waE2E.ProtocolMessage_REVOKE.Enum(),
				Key:  revokeKey,
			},
		},
	}
	c.dispatchMessage(evt)
	e := sink.wait(t, "MessageRevoked", time.Second)
	var got JMessageRevoked
	if err := json.Unmarshal([]byte(e.payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.MessageID != "MSG-TO-REVOKE" {
		t.Errorf("MessageID = %q", got.MessageID)
	}
	if got.RevokedBy != sender.String() {
		t.Errorf("RevokedBy = %q", got.RevokedBy)
	}
}

func TestDispatchEditEmitsMessageEdited(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/edit.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("12345@s.whatsapp.net")
	sender, _ := types.ParseJID("67890@s.whatsapp.net")
	editKey := &waCommon.MessageKey{ID: proto.String("MSG-EDITED")}
	evt := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sender},
			ID:            "EDIT-ENVELOPE",
			Timestamp:     time.Unix(1700000050, 0),
		},
		Message: &waE2E.Message{
			ProtocolMessage: &waE2E.ProtocolMessage{
				Type: waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(),
				Key:  editKey,
				EditedMessage: &waE2E.Message{
					Conversation: proto.String("new text"),
				},
			},
		},
	}
	c.dispatchMessage(evt)
	e := sink.wait(t, "MessageEdited", time.Second)
	var got JMessageEdited
	if err := json.Unmarshal([]byte(e.payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.MessageID != "MSG-EDITED" || got.NewText != "new text" {
		t.Errorf("got = %+v", got)
	}
}

func TestDispatchReplyPopulatesQuoted(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/quoted.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("12345@s.whatsapp.net")
	sender, _ := types.ParseJID("67890@s.whatsapp.net")
	evt := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sender},
			ID:            "REPLY-MSG",
			Timestamp:     time.Unix(1700000100, 0),
		},
		Message: &waE2E.Message{
			ExtendedTextMessage: &waE2E.ExtendedTextMessage{
				Text: proto.String("yes please"),
				ContextInfo: &waE2E.ContextInfo{
					StanzaID:    proto.String("ORIG-ID"),
					Participant: proto.String("99999@s.whatsapp.net"),
					QuotedMessage: &waE2E.Message{
						Conversation: proto.String("dinner at 7?"),
					},
				},
			},
		},
	}
	c.dispatchMessage(evt)
	e := sink.wait(t, "Message", time.Second)
	var got JMessage
	if err := json.Unmarshal([]byte(e.payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.Quoted == nil {
		t.Fatal("Quoted nil")
	}
	if got.Quoted.MessageID != "ORIG-ID" {
		t.Errorf("MessageID = %q", got.Quoted.MessageID)
	}
	if got.Quoted.Kind != "text" {
		t.Errorf("Kind = %q", got.Quoted.Kind)
	}
	if got.Quoted.Snippet != "dinner at 7?" {
		t.Errorf("Snippet = %q", got.Quoted.Snippet)
	}
}
