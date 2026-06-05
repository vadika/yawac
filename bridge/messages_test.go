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
	_, err = c.SendText("not-a-jid", "hi", "", 0)
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
		"text", "hello", "", 0)
	if err == nil {
		t.Fatal("expected error for bad chat jid")
	}
}

func TestSendTextReplyClosedClient(t *testing.T) {
	c := &Client{} // wa is nil
	_, err := c.SendTextReply("12345@s.whatsapp.net", "hi",
		"ABCD1234", "12345@s.whatsapp.net", false,
		"text", "hello", "", 0)
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

func TestWrapForChatNoWrap(t *testing.T) {
	inner := &waE2E.Message{
		Conversation: proto.String("hello"),
	}
	out := wrapForChat(inner, 0, false)
	if out != inner {
		t.Fatal("expected unchanged inner when no wrapping requested")
	}
}

func TestWrapForChatEphemeralOnly(t *testing.T) {
	inner := &waE2E.Message{
		Conversation: proto.String("hi"),
	}
	out := wrapForChat(inner, 86400, false)
	if out.EphemeralMessage == nil {
		t.Fatal("expected EphemeralMessage wrap")
	}
	if out.EphemeralMessage.Message == nil {
		t.Fatal("inner should still be set on wrapper")
	}
	if out.ViewOnceMessageV2 != nil {
		t.Fatal("unexpected ViewOnce wrap")
	}
}

func TestWrapForChatViewOnceOnly(t *testing.T) {
	inner := &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{},
	}
	out := wrapForChat(inner, 0, true)
	if out.ViewOnceMessageV2 == nil {
		t.Fatal("expected ViewOnceMessageV2 wrap")
	}
	if out.EphemeralMessage != nil {
		t.Fatal("unexpected Ephemeral wrap")
	}
}

func TestWrapForChatBothEphemeralOutside(t *testing.T) {
	inner := &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{},
	}
	out := wrapForChat(inner, 86400, true)
	if out.EphemeralMessage == nil {
		t.Fatal("expected outer EphemeralMessage wrap")
	}
	if out.EphemeralMessage.Message == nil ||
		out.EphemeralMessage.Message.ViewOnceMessageV2 == nil {
		t.Fatalf("expected ViewOnceMessageV2 inside EphemeralMessage; got %+v",
			out.EphemeralMessage.Message)
	}
}

func TestSendLocationUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sl.db")
	defer c.Close()
	_, err := c.SendLocation("1234@s.whatsapp.net", 60.17, 24.94, "Senate Square", "Helsinki", 0)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendLocationBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sl2.db")
	defer c.Close()
	_, err := c.SendLocation("not a jid", 60.17, 24.94, "", "", 0)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestSendContactUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sc.db")
	defer c.Close()
	vcard := "BEGIN:VCARD\nVERSION:3.0\nFN:Anna\nTEL;type=CELL;waid=12345:+12345\nEND:VCARD"
	_, err := c.SendContact("1234@s.whatsapp.net", vcard, "Anna", 0)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendContactBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sc2.db")
	defer c.Close()
	_, err := c.SendContact("not a jid", "BEGIN:VCARD\nEND:VCARD", "X", 0)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestClassifyInboundLocation(t *testing.T) {
	m := &waE2E.Message{
		LocationMessage: &waE2E.LocationMessage{
			DegreesLatitude:  proto.Float64(60.17),
			DegreesLongitude: proto.Float64(24.94),
			Name:             proto.String("Senate Square"),
			Address:          proto.String("Helsinki"),
		},
	}
	kind, loc, _, _, _ := classifyMessage(m)
	if kind != "location" {
		t.Fatalf("kind=%s", kind)
	}
	if loc == nil || loc.Lat != 60.17 || loc.Lng != 24.94 {
		t.Fatalf("loc=%+v", loc)
	}
	if loc.Name != "Senate Square" || loc.Address != "Helsinki" {
		t.Fatalf("loc name/address mismatch: %+v", loc)
	}
}

func TestClassifyInboundLiveLocation(t *testing.T) {
	m := &waE2E.Message{
		LiveLocationMessage: &waE2E.LiveLocationMessage{
			DegreesLatitude:  proto.Float64(60.17),
			DegreesLongitude: proto.Float64(24.94),
			SequenceNumber:   proto.Int64(42),
		},
	}
	kind, loc, seq, _, _ := classifyMessage(m)
	if kind != "location_live" || seq != 42 {
		t.Fatalf("kind=%s seq=%d", kind, seq)
	}
	if loc == nil || loc.Lat != 60.17 || loc.Lng != 24.94 {
		t.Fatalf("loc=%+v", loc)
	}
}

func TestClassifyInboundContact(t *testing.T) {
	m := &waE2E.Message{
		ContactMessage: &waE2E.ContactMessage{
			DisplayName: proto.String("Anna"),
			Vcard:       proto.String("BEGIN:VCARD\nEND:VCARD"),
		},
	}
	kind, _, _, contact, _ := classifyMessage(m)
	if kind != "contact" {
		t.Fatalf("kind=%s", kind)
	}
	if contact == nil || contact.DisplayName != "Anna" {
		t.Fatalf("contact=%+v", contact)
	}
	if contact.Vcard != "BEGIN:VCARD\nEND:VCARD" {
		t.Fatalf("vcard mismatch: %q", contact.Vcard)
	}
}

func TestClassifyInboundViewOnce(t *testing.T) {
	m := &waE2E.Message{
		ViewOnceMessageV2: &waE2E.FutureProofMessage{
			Message: &waE2E.Message{
				ImageMessage: &waE2E.ImageMessage{},
			},
		},
	}
	kind, _, _, _, isViewOnce := classifyMessage(m)
	if kind != "image" {
		t.Fatalf("expected unwrap to image, got %s", kind)
	}
	if !isViewOnce {
		t.Fatal("expected isViewOnce=true after unwrap")
	}
}

func TestExtractContextInfoExpirationFromExtendedText(t *testing.T) {
	m := &waE2E.Message{
		ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String("hi"),
			ContextInfo: &waE2E.ContextInfo{
				Expiration: proto.Uint32(86400),
			},
		},
	}
	if got := extractContextInfoExpiration(m); got != 86400 {
		t.Fatalf("want 86400 got %d", got)
	}
}

func TestExtractContextInfoExpirationFromImage(t *testing.T) {
	m := &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{
			ContextInfo: &waE2E.ContextInfo{
				Expiration: proto.Uint32(604800),
			},
		},
	}
	if got := extractContextInfoExpiration(m); got != 604800 {
		t.Fatalf("want 604800 got %d", got)
	}
}

func TestExtractContextInfoExpirationZeroWhenAbsent(t *testing.T) {
	m := &waE2E.Message{
		Conversation: proto.String("plain text, no context info"),
	}
	if got := extractContextInfoExpiration(m); got != 0 {
		t.Fatalf("want 0 got %d", got)
	}
}

func TestDispatchEmitsEphemeralTimerOnInboundWithExpiration(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/exp.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("79215925086@s.whatsapp.net")
	sender, _ := types.ParseJID("79215925086@s.whatsapp.net")
	evt := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sender},
			ID:            "EXP-HINT-1",
			Timestamp:     time.Unix(1700000200, 0),
		},
		Message: &waE2E.Message{
			ExtendedTextMessage: &waE2E.ExtendedTextMessage{
				Text: proto.String("disappearing hello"),
				ContextInfo: &waE2E.ContextInfo{
					Expiration: proto.Uint32(86400),
				},
			},
		},
	}
	c.dispatchMessage(evt)
	e := sink.wait(t, "EphemeralTimerChanged", time.Second)
	var got JEphemeralTimerChanged
	if err := json.Unmarshal([]byte(e.payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.ChatJID != chat.String() {
		t.Errorf("ChatJID = %q", got.ChatJID)
	}
	if got.Seconds != 86400 {
		t.Errorf("Seconds = %d", got.Seconds)
	}
}

func TestSendReactionEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sr.db")
	defer c.Close()
	_, err := c.SendReaction("1@s.whatsapp.net", "MSG1", "1@s.whatsapp.net", false, "👍", 86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendReactionSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, string, bool, string, int32) (string, error) =
		func(c *Client) func(string, string, string, bool, string, int32) (string, error) {
			return c.SendReaction
		}
}

func TestSendTextReplyEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/str.db")
	defer c.Close()
	_, err := c.SendTextReply(
		"1@s.whatsapp.net", "hi",
		"QUOTEDMSG", "1@s.whatsapp.net", false,
		"text", "previous",
		`[]`,
		86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSendTextReplySignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, string, string, bool, string, string, string, int32) (string, error) =
		func(c *Client) func(string, string, string, string, bool, string, string, string, int32) (string, error) {
			return c.SendTextReply
		}
}

func TestForwardTextEphemeralWrap(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ft.db")
	defer c.Close()
	_, err := c.ForwardText("1@s.whatsapp.net", "hi", 86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestForwardTextSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, int32) (string, error) =
		func(c *Client) func(string, string, int32) (string, error) {
			return c.ForwardText
		}
}
