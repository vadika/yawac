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

func TestMuteJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/mu.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("1234567890@s.whatsapp.net")
	c.dispatchMute(&events.Mute{
		JID:       jid,
		Timestamp: time.Unix(1700000000, 0),
		Action: &waSyncAction.MuteAction{
			Muted:            proto.Bool(true),
			MuteEndTimestamp: proto.Int64(1700000000000),
		},
	})
	e := sink.wait(t, "ChatMuted", time.Second)
	var j JChatMuted
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.ChatJID != "1234567890@s.whatsapp.net" {
		t.Errorf("ChatJID=%s", j.ChatJID)
	}
	if j.MutedUntilMs != 1700000000000 {
		t.Errorf("MutedUntilMs=%d", j.MutedUntilMs)
	}
	if j.Timestamp != 1700000000 {
		t.Errorf("Timestamp=%d", j.Timestamp)
	}
}

func TestMuteUnmuteJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/mu2.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid, _ := types.ParseJID("1234567890@s.whatsapp.net")
	c.dispatchMute(&events.Mute{
		JID:       jid,
		Timestamp: time.Unix(1700000000, 0),
		Action: &waSyncAction.MuteAction{
			Muted:            proto.Bool(false),
			MuteEndTimestamp: proto.Int64(1700000000000),
		},
	})
	e := sink.wait(t, "ChatMuted", time.Second)
	var j JChatMuted
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.MutedUntilMs != 0 {
		t.Errorf("unmute should zero MutedUntilMs, got %d", j.MutedUntilMs)
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

func TestGroupInfoNameOnlyJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gn.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid := types.JID{User: "111", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       jid,
		Timestamp: time.Unix(1700000000, 0),
		Name:      &types.GroupName{Name: "New Name"},
	})
	e := sink.wait(t, "GroupInfoChanged", time.Second)
	var j JGroupInfoChanged
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.Name != "New Name" || j.Description != "" {
		t.Errorf("got %+v", j)
	}
}

func TestGroupInfoTopicOnlyJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gt.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid := types.JID{User: "111", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       jid,
		Timestamp: time.Unix(1700000000, 0),
		Topic:     &types.GroupTopic{Topic: "New description"},
	})
	e := sink.wait(t, "GroupInfoChanged", time.Second)
	var j JGroupInfoChanged
	if err := json.Unmarshal([]byte(e.payload), &j); err != nil {
		t.Fatal(err)
	}
	if j.Description != "New description" || j.Name != "" {
		t.Errorf("got %+v", j)
	}
}

func TestGroupInfoNeitherSkipsDispatch(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gz.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid := types.JID{User: "111", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       jid,
		Timestamp: time.Unix(1700000000, 0),
	})
	// No dispatch expected. dispatch is async (a goroutine in c.dispatch),
	// so give it a brief grace period before asserting silence.
	time.Sleep(50 * time.Millisecond)
	sink.mu.Lock()
	n := len(sink.events)
	sink.mu.Unlock()
	if n != 0 {
		t.Fatalf("unexpected dispatch: %+v", sink.events)
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
