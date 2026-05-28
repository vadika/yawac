package bridge

import (
	"encoding/json"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
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

func TestArchiveJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ar.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchArchive(&events.Archive{
		JID:       jid,
		Timestamp: time.Unix(7, 0),
		Action:    &waSyncAction.ArchiveChatAction{Archived: proto.Bool(true)},
	})
	e := sink.wait(t, "ChatArchived", time.Second)
	var j JChatArchived
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.ChatJID != "12345@s.whatsapp.net" || !j.Archived || j.Timestamp != 7 {
		t.Fatalf("bad archive: %+v", j)
	}
}

func TestDeleteChatJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/dc.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchDeleteChat(&events.DeleteChat{JID: jid, Timestamp: time.Unix(9, 0)})
	e := sink.wait(t, "ChatDeleted", time.Second)
	var j JChatDeleted
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.ChatJID != "12345@s.whatsapp.net" || j.Timestamp != 9 {
		t.Fatalf("bad delete: %+v", j)
	}
}

func TestContactJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/co.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchContact(&events.Contact{
		JID:    jid,
		Action: &waSyncAction.ContactAction{FullName: proto.String("Bob"), FirstName: proto.String("B")},
	})
	e := sink.wait(t, "ContactUpdated", time.Second)
	var j JContactUpdated
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.JID != "12345@s.whatsapp.net" || j.FullName != "Bob" || j.FirstName != "B" {
		t.Fatalf("bad contact: %+v", j)
	}
}

func TestBlocklistJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/bl.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchBlocklist(&events.Blocklist{
		Action: events.BlocklistActionDefault,
		Changes: []events.BlocklistChange{
			{JID: jid, Action: events.BlocklistChangeActionBlock},
		},
	})
	e := sink.wait(t, "BlocklistChanged", time.Second)
	var j JBlocklistChanged
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if len(j.Changes) != 1 || j.Changes[0].JID != "12345@s.whatsapp.net" || j.Changes[0].Action != "block" {
		t.Fatalf("bad blocklist: %+v", j)
	}
}
