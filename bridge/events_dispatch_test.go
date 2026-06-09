package bridge

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	waBinary "go.mau.fi/whatsmeow/binary"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
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

func TestDispatchGroupParticipantsAddOnly(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gp1.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("123@g.us")
	sender, _ := types.ParseJID("999@s.whatsapp.net")
	j1, _ := types.ParseJID("1@s.whatsapp.net")
	j2, _ := types.ParseJID("2@s.whatsapp.net")
	c.dispatchGroupParticipants(&events.GroupInfo{
		JID:       chat,
		Sender:    &sender,
		Join:      []types.JID{j1, j2},
		Timestamp: time.Unix(100, 0),
	})
	e := sink.wait(t, "GroupParticipantsChanged", time.Second)
	var jp JGroupParticipantsChanged
	if err := json.Unmarshal([]byte(e.payload), &jp); err != nil {
		t.Fatal(err)
	}
	if jp.Action != "add" || len(jp.JIDs) != 2 ||
		jp.ChatJID != "123@g.us" || jp.ActorJID != "999@s.whatsapp.net" ||
		jp.Timestamp != 100 {
		t.Fatalf("bad payload: %+v", jp)
	}
}

func TestDispatchGroupParticipantsAllFourActions(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gp2.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("123@g.us")
	j1, _ := types.ParseJID("1@s.whatsapp.net")
	c.dispatchGroupParticipants(&events.GroupInfo{
		JID:       chat,
		Join:      []types.JID{j1},
		Leave:     []types.JID{j1},
		Promote:   []types.JID{j1},
		Demote:    []types.JID{j1},
		Timestamp: time.Unix(7, 0),
	})
	actions := map[string]bool{}
	for i := 0; i < 4; i++ {
		e := sink.wait(t, "GroupParticipantsChanged", time.Second)
		var jp JGroupParticipantsChanged
		if err := json.Unmarshal([]byte(e.payload), &jp); err != nil {
			t.Fatal(err)
		}
		actions[jp.Action] = true
	}
	for _, k := range []string{"add", "remove", "promote", "demote"} {
		if !actions[k] {
			t.Fatalf("missing action %q in %v", k, actions)
		}
	}
}

func TestDispatchGroupParticipantsNoSender(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gp3.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("123@g.us")
	j1, _ := types.ParseJID("1@s.whatsapp.net")
	c.dispatchGroupParticipants(&events.GroupInfo{
		JID:       chat,
		Join:      []types.JID{j1},
		Timestamp: time.Unix(1, 0),
	})
	e := sink.wait(t, "GroupParticipantsChanged", time.Second)
	var jp JGroupParticipantsChanged
	if err := json.Unmarshal([]byte(e.payload), &jp); err != nil {
		t.Fatal(err)
	}
	if jp.ActorJID != "" {
		t.Fatalf("expected empty ActorJID, got %q", jp.ActorJID)
	}
}

func TestDispatchGroupParticipantsEmptyAllNoEvents(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gp4.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("123@g.us")
	c.dispatchGroupParticipants(&events.GroupInfo{
		JID: chat, Timestamp: time.Unix(1, 0),
	})
	select {
	case e := <-sink.ch:
		t.Fatalf("expected no events, got %+v", e)
	case <-time.After(100 * time.Millisecond):
	}
}

// findInSink scans the sink's recorded events for the first one with the
// given kind. Returns nil if not found. Gives the goroutine dispatch a brief
// grace window so all expected events are present before we look.
func findInSink(sink *recSink, kind string) *recEvent {
	deadline := time.Now().Add(200 * time.Millisecond)
	for time.Now().Before(deadline) {
		sink.mu.Lock()
		for i, e := range sink.events {
			if e.kind == kind {
				out := sink.events[i]
				sink.mu.Unlock()
				return &out
			}
		}
		sink.mu.Unlock()
		time.Sleep(10 * time.Millisecond)
	}
	return nil
}

func boolJSON(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// TestDispatchGroupInfoCarriesLinkedParentAndDefaultSub verifies that when
// a GroupInfo arrives for a sub-group that was linked under a community
// parent, the GroupInfoChanged payload carries both linked_parent_jid and
// is_default_subgroup. whatsmeow exposes this via evt.Link, not via
// direct fields on events.GroupInfo, so the test wires it that way.
func TestDispatchGroupInfoCarriesLinkedParentAndDefaultSub(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_lp.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	parent, _ := types.ParseJID("1111@g.us")
	sub, _ := types.ParseJID("2222@g.us")
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       sub,
		Name:      &types.GroupName{Name: "Sub"},
		Timestamp: time.Unix(1700000000, 0),
		Link: &types.GroupLinkChange{
			Type: types.GroupLinkChangeTypeParent,
			Group: types.GroupLinkTarget{
				JID:               parent,
				GroupIsDefaultSub: types.GroupIsDefaultSub{IsDefaultSubGroup: true},
			},
		},
	})
	ev := sink.wait(t, "GroupInfoChanged", time.Second)
	if !strings.Contains(ev.payload, `"linked_parent_jid":"1111@g.us"`) {
		t.Errorf("missing linked_parent_jid: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"is_default_subgroup":true`) {
		t.Errorf("missing is_default_subgroup: %s", ev.payload)
	}
}

// TestDispatchGroupInfoFiresApprovalModeChanged covers the new
// JoinApprovalModeChanged fan-out. whatsmeow uses bool
// IsJoinApprovalRequired (not the "request_required" string in the spec).
func TestDispatchGroupInfoFiresApprovalModeChanged(t *testing.T) {
	cases := []struct {
		required bool
		wantOn   bool
	}{
		{true, true},
		{false, false},
	}
	for _, tc := range cases {
		c, _ := NewClient(t.TempDir() + "/gi_ap.db")
		sink := newRecSink()
		c.SetEventSink(sink)
		jid := types.JID{User: "3333", Server: types.GroupServer}
		c.dispatchGroupInfo(&events.GroupInfo{
			JID: jid,
			MembershipApprovalMode: &types.GroupMembershipApprovalMode{
				IsJoinApprovalRequired: tc.required,
			},
			Timestamp: time.Unix(1700000001, 0),
		})
		ev := sink.wait(t, "JoinApprovalModeChanged", time.Second)
		wantOnJSON := `"on":` + boolJSON(tc.wantOn)
		if !strings.Contains(ev.payload, wantOnJSON) {
			t.Errorf("required=%v: payload=%s want contains %s",
				tc.required, ev.payload, wantOnJSON)
		}
		c.Close()
	}
}

// TestDispatchGroupInfoFiresBothNameAndApprovalMode confirms a single
// events.GroupInfo can fan out into both a GroupInfoChanged and a
// JoinApprovalModeChanged event in one call.
func TestDispatchGroupInfoFiresBothNameAndApprovalMode(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_both.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	jid := types.JID{User: "4444", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:  jid,
		Name: &types.GroupName{Name: "Renamed"},
		MembershipApprovalMode: &types.GroupMembershipApprovalMode{
			IsJoinApprovalRequired: true,
		},
		Timestamp: time.Unix(1700000002, 0),
	})
	if findInSink(sink, "GroupInfoChanged") == nil {
		t.Error("missing GroupInfoChanged")
	}
	if findInSink(sink, "JoinApprovalModeChanged") == nil {
		t.Error("missing JoinApprovalModeChanged")
	}
}

// TestDispatchGroupInfoFiresEphemeralTimerChangedOnGroupChange verifies
// that when whatsmeow surfaces a GroupInfo carrying a non-nil Ephemeral
// (disappearing messages change), dispatchGroupInfo fans out an
// EphemeralTimerChanged event with the new disappearing-timer seconds.
func TestDispatchGroupInfoFiresEphemeralTimerChangedOnGroupChange(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_eph.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat := types.JID{User: "888", Server: types.GroupServer}
	sender, _ := types.ParseJID("999@s.whatsapp.net")
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:    chat,
		Sender: &sender,
		Ephemeral: &types.GroupEphemeral{
			IsEphemeral:       true,
			DisappearingTimer: 86400,
		},
		Timestamp: time.Unix(1700000000, 0),
	})
	ev := sink.wait(t, "EphemeralTimerChanged", time.Second)
	if !strings.Contains(ev.payload, `"seconds":86400`) {
		t.Errorf("payload missing seconds: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"chat_jid":"888@g.us"`) {
		t.Errorf("payload missing chat_jid: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"actor_jid":"999@s.whatsapp.net"`) {
		t.Errorf("payload missing actor_jid: %s", ev.payload)
	}
}

// TestDispatchEphemeralTimerChangedOnDirectMessage verifies that a 1:1
// inbound carrier message whose ProtocolMessage type is EPHEMERAL_SETTING
// is intercepted into an EphemeralTimerChanged event and the regular
// MessageReceived ("Message") dispatch is suppressed.
func TestDispatchEphemeralTimerChangedOnDirectMessage(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/dm_eph.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat, _ := types.ParseJID("12345@s.whatsapp.net")
	sender, _ := types.ParseJID("12345@s.whatsapp.net")
	c.dispatchMessage(&events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sender},
			ID:            "x",
			Timestamp:     time.Unix(1700000001, 0),
		},
		Message: &waE2E.Message{
			ProtocolMessage: &waE2E.ProtocolMessage{
				Type:                waE2E.ProtocolMessage_EPHEMERAL_SETTING.Enum(),
				EphemeralExpiration: proto.Uint32(604800),
			},
		},
	})
	ev := sink.wait(t, "EphemeralTimerChanged", time.Second)
	if !strings.Contains(ev.payload, `"seconds":604800`) {
		t.Errorf("payload missing seconds: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"chat_jid":"12345@s.whatsapp.net"`) {
		t.Errorf("payload missing chat_jid: %s", ev.payload)
	}
	// F35: the carrier itself is still suppressed (no `text` body, no
	// `kind` field, etc.), but yawac now emits a synthetic Message
	// with kind="system" carrying a friendly description so the user
	// sees the timer change as an inline chat row. Verify it's there
	// with the expected shape.
	msg := findInSink(sink, "Message")
	if msg == nil {
		t.Fatal("expected synthetic system Message for EphemeralSetting")
	}
	if !strings.Contains(msg.payload, `"kind":"system"`) {
		t.Errorf("expected kind=system, got %s", msg.payload)
	}
	if !strings.Contains(msg.payload, "Disappearing messages turned on") {
		t.Errorf("expected friendly disappearing-on text, got %s", msg.payload)
	}
}

// TestDispatchGroupInfoFiresGroupAnnounceChanged verifies that when
// whatsmeow surfaces a GroupInfo carrying a non-nil Announce (admin-only
// posting toggle), dispatchGroupInfo fans out a GroupAnnounceChanged
// event with the new on/off flag.
func TestDispatchGroupInfoFiresGroupAnnounceChanged(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_ann.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat := types.JID{User: "888", Server: types.GroupServer}
	sender, _ := types.ParseJID("999@s.whatsapp.net")
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       chat,
		Sender:    &sender,
		Announce:  &types.GroupAnnounce{IsAnnounce: true},
		Timestamp: time.Unix(1700000000, 0),
	})
	ev := sink.wait(t, "GroupAnnounceChanged", time.Second)
	if !strings.Contains(ev.payload, `"on":true`) {
		t.Errorf("payload missing on=true: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"chat_jid":"888@g.us"`) {
		t.Errorf("payload missing chat_jid: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"actor_jid":"999@s.whatsapp.net"`) {
		t.Errorf("payload missing actor_jid: %s", ev.payload)
	}
}

// TestDispatchGroupInfoFiresGroupLockedChanged verifies that when
// whatsmeow surfaces a GroupInfo carrying a non-nil Locked (admin-only
// edit-info toggle), dispatchGroupInfo fans out a GroupLockedChanged
// event with the new on/off flag.
func TestDispatchGroupInfoFiresGroupLockedChanged(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_lck.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat := types.JID{User: "888", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       chat,
		Locked:    &types.GroupLocked{IsLocked: false},
		Timestamp: time.Unix(1700000000, 0),
	})
	ev := sink.wait(t, "GroupLockedChanged", time.Second)
	if !strings.Contains(ev.payload, `"on":false`) {
		t.Errorf("payload missing on=false: %s", ev.payload)
	}
	if !strings.Contains(ev.payload, `"chat_jid":"888@g.us"`) {
		t.Errorf("payload missing chat_jid: %s", ev.payload)
	}
}

// TestDispatchGroupInfoFiresGroupMemberAddModeChanged verifies that
// when the server fans out a peer-driven member_add_mode change,
// dispatchGroupInfo plucks it out of UnknownChanges and emits a
// typed GroupMemberAddModeChanged event. whatsmeow does not promote
// this to a typed field on events.GroupInfo (unlike Announce / Locked
// / Ephemeral), so the dispatcher walks the raw node list.
func TestDispatchGroupInfoFiresGroupMemberAddModeChanged(t *testing.T) {
	cases := []struct {
		mode   string
		wantOn bool
	}{
		{"all_member_add", true},
		{"admin_add", false},
	}
	for _, tc := range cases {
		c, _ := NewClient(t.TempDir() + "/gi_mam_" + tc.mode + ".db")
		sink := newRecSink()
		c.SetEventSink(sink)
		chat := types.JID{User: "888", Server: types.GroupServer}
		sender, _ := types.ParseJID("999@s.whatsapp.net")
		c.dispatchGroupInfo(&events.GroupInfo{
			JID:       chat,
			Sender:    &sender,
			Timestamp: time.Unix(1700000000, 0),
			UnknownChanges: []*waBinary.Node{
				{Tag: "member_add_mode", Content: []byte(tc.mode)},
			},
		})
		ev := sink.wait(t, "GroupMemberAddModeChanged", time.Second)
		wantOnJSON := `"all_members_can_add":` + boolJSON(tc.wantOn)
		if !strings.Contains(ev.payload, wantOnJSON) {
			t.Errorf("mode=%q payload=%s want contains %s",
				tc.mode, ev.payload, wantOnJSON)
		}
		if !strings.Contains(ev.payload, `"chat_jid":"888@g.us"`) {
			t.Errorf("payload missing chat_jid: %s", ev.payload)
		}
		if !strings.Contains(ev.payload, `"actor_jid":"999@s.whatsapp.net"`) {
			t.Errorf("payload missing actor_jid: %s", ev.payload)
		}
		c.Close()
	}
}

// TestDispatchGroupInfoMemberAddModeStringContent guards the helper
// against string-typed Content (whatsmeow Node.Content is interface{}).
func TestDispatchGroupInfoMemberAddModeStringContent(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_mam_s.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat := types.JID{User: "777", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       chat,
		Timestamp: time.Unix(1700000000, 0),
		UnknownChanges: []*waBinary.Node{
			{Tag: "member_add_mode", Content: "all_member_add"},
		},
	})
	ev := sink.wait(t, "GroupMemberAddModeChanged", time.Second)
	if !strings.Contains(ev.payload, `"all_members_can_add":true`) {
		t.Errorf("payload: %s", ev.payload)
	}
}

// TestDispatchGroupInfoMemberAddModeAbsentNoEmit confirms we skip the
// dispatch when UnknownChanges does not include a member_add_mode node.
func TestDispatchGroupInfoMemberAddModeAbsentNoEmit(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi_mam_none.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)
	chat := types.JID{User: "666", Server: types.GroupServer}
	c.dispatchGroupInfo(&events.GroupInfo{
		JID:       chat,
		Timestamp: time.Unix(1700000000, 0),
		UnknownChanges: []*waBinary.Node{
			{Tag: "unrelated", Content: []byte("noise")},
		},
	})
	time.Sleep(80 * time.Millisecond)
	if findInSink(sink, "GroupMemberAddModeChanged") != nil {
		t.Fatal("unexpected GroupMemberAddModeChanged dispatch")
	}
}
