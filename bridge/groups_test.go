package bridge

import (
	"encoding/json"
	"testing"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

func TestListGroupsReturnsArray(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/g.db")
	defer c.Close()
	s, err := c.ListGroups()
	if err != nil {
		// Unpaired client may not be able to fetch groups; that's fine.
		t.Skipf("ListGroups on unpaired client: %v", err)
	}
	var arr []JGroup
	if err := json.Unmarshal([]byte(s), &arr); err != nil {
		t.Fatalf("decode: %v (%s)", err, s)
	}
}

func TestUpdateGroupParticipantsActionMapping(t *testing.T) {
	cases := []struct {
		in   string
		want whatsmeow.ParticipantChange
		ok   bool
	}{
		{"add", whatsmeow.ParticipantChangeAdd, true},
		{"remove", whatsmeow.ParticipantChangeRemove, true},
		{"promote", whatsmeow.ParticipantChangePromote, true},
		{"demote", whatsmeow.ParticipantChangeDemote, true},
		{"banish", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, err := participantChangeFromString(c.in)
		if c.ok && (err != nil || got != c.want) {
			t.Fatalf("%q: got (%q,%v) want (%q,nil)", c.in, got, err, c.want)
		}
		if !c.ok && err == nil {
			t.Fatalf("%q: expected error, got nil", c.in)
		}
	}
}

func TestUpdateGroupParticipantsUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/u.db")
	defer c.Close()
	_, err := c.UpdateGroupParticipants(
		"1234@g.us", "add",
		`["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupPhotoUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sp.db")
	defer c.Close()
	_, err := c.SetGroupPhoto("1234@g.us", []byte{0xff, 0xd8, 0xff})
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestRemoveGroupPhotoUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/rp.db")
	defer c.Close()
	err := c.RemoveGroupPhoto("1234@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestGetGroupInviteLinkUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/il.db")
	defer c.Close()
	_, err := c.GetGroupInviteLink("1234@g.us", false)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestStripInviteCodePrefix(t *testing.T) {
	cases := []struct{ in, want string }{
		{"AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
		{"chat.whatsapp.com/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
		{"https://chat.whatsapp.com/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
		{"http://chat.whatsapp.com/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
		{"wa.me/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
		{"https://wa.me/AbCdEfGhIjKlMn", "AbCdEfGhIjKlMn"},
	}
	for _, c := range cases {
		if got := stripInviteCodePrefix(c.in); got != c.want {
			t.Errorf("strip(%q)=%q want %q", c.in, got, c.want)
		}
	}
}

func TestGroupInfoFromLinkUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gi.db")
	defer c.Close()
	_, err := c.GroupInfoFromLink("AbCdEfGhIjKlMn")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestJoinGroupViaLinkUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/jl.db")
	defer c.Close()
	_, err := c.JoinGroupViaLink("AbCdEfGhIjKlMn")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestCreateCommunityUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/cc.db")
	defer c.Close()
	_, err := c.CreateCommunity("Outdoor Club")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestCreateCommunityClosed(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/cc2.db")
	c.Close()
	_, err := c.CreateCommunity("Outdoor Club")
	if err == nil {
		t.Fatal("expected error on closed client")
	}
}

func TestCreateSubGroupUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/csg.db")
	defer c.Close()
	_, err := c.CreateSubGroup(
		"1234@g.us", "Hiking", `["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestCreateSubGroupBadParentJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/csg2.db")
	defer c.Close()
	_, err := c.CreateSubGroup("not a jid", "Hiking", `[]`)
	if err == nil {
		t.Fatal("expected parse error on bad parent JID")
	}
}

func TestCreateSubGroupBadParticipantJSON(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/csg3.db")
	defer c.Close()
	_, err := c.CreateSubGroup("1234@g.us", "Hiking", "not json")
	if err == nil {
		t.Fatal("expected parse error on bad participant JSON")
	}
}

func TestLinkSubGroupUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ls.db")
	defer c.Close()
	err := c.LinkSubGroup("1111@g.us", "2222@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestLinkSubGroupBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ls2.db")
	defer c.Close()
	err := c.LinkSubGroup("not a jid", "2222@g.us")
	if err == nil {
		t.Fatal("expected parse error on bad parent JID")
	}
	err = c.LinkSubGroup("1111@g.us", "not a jid")
	if err == nil {
		t.Fatal("expected parse error on bad sub JID")
	}
}

func TestUnlinkSubGroupUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/us.db")
	defer c.Close()
	err := c.UnlinkSubGroup("1111@g.us", "2222@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestUnlinkSubGroupBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/us2.db")
	defer c.Close()
	err := c.UnlinkSubGroup("not a jid", "2222@g.us")
	if err == nil {
		t.Fatal("expected parse error on bad parent JID")
	}
}

func TestGetGroupJoinRequestsUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gjr.db")
	defer c.Close()
	_, err := c.GetGroupJoinRequests("1234@g.us")
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestGetGroupJoinRequestsBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/gjr2.db")
	defer c.Close()
	_, err := c.GetGroupJoinRequests("not a jid")
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestJJoinRequestJSONShape(t *testing.T) {
	in := JJoinRequest{JID: "1111@s.whatsapp.net", RequestedAt: 1234567890}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	want := `{"jid":"1111@s.whatsapp.net","requested_at":1234567890}`
	if got != want {
		t.Fatalf("JSON mismatch:\ngot:  %s\nwant: %s", got, want)
	}
}

func TestJoinRequestChangeFromString(t *testing.T) {
	cases := []struct {
		in   string
		want whatsmeow.ParticipantRequestChange
		ok   bool
	}{
		{"approve", whatsmeow.ParticipantChangeApprove, true},
		{"reject", whatsmeow.ParticipantChangeReject, true},
		{"banish", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, err := joinRequestChangeFromString(c.in)
		if c.ok && (err != nil || got != c.want) {
			t.Fatalf("%q: got (%q,%v) want (%q,nil)", c.in, got, err, c.want)
		}
		if !c.ok && err == nil {
			t.Fatalf("%q: expected error, got nil", c.in)
		}
	}
}

func TestUpdateGroupJoinRequestsUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ujr.db")
	defer c.Close()
	_, err := c.UpdateGroupJoinRequests(
		"1234@g.us", "approve",
		`["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestUpdateGroupJoinRequestsInvalidAction(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/ujr2.db")
	defer c.Close()
	_, err := c.UpdateGroupJoinRequests(
		"1234@g.us", "banish",
		`["1111@s.whatsapp.net"]`)
	if err == nil {
		t.Fatal("expected error for invalid action")
	}
}

func TestJJoinRequestResultJSONShape(t *testing.T) {
	in := JJoinRequestResult{JID: "1@s.whatsapp.net", ErrorCode: 403}
	b, _ := json.Marshal(in)
	want := `{"jid":"1@s.whatsapp.net","error_code":403}`
	if string(b) != want {
		t.Fatalf("got %s want %s", b, want)
	}
}

func TestSetGroupJoinApprovalModeUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sm.db")
	defer c.Close()
	err := c.SetGroupJoinApprovalMode("1234@g.us", true)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupJoinApprovalModeBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sm2.db")
	defer c.Close()
	err := c.SetGroupJoinApprovalMode("not a jid", true)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestMapGroupInfoCarriesJoinApprovalMode(t *testing.T) {
	in := &types.GroupInfo{
		JID:       types.NewJID("5555", "g.us"),
		GroupName: types.GroupName{Name: "Test"},
		GroupMembershipApprovalMode: types.GroupMembershipApprovalMode{
			IsJoinApprovalRequired: true,
		},
	}
	got := mapGroupInfo(in)
	if !got.JoinApprovalMode {
		t.Fatalf("expected JoinApprovalMode true, got %+v", got)
	}
	in.GroupMembershipApprovalMode.IsJoinApprovalRequired = false
	got = mapGroupInfo(in)
	if got.JoinApprovalMode {
		t.Fatalf("expected JoinApprovalMode false, got %+v", got)
	}
}

func TestSetDisappearingTimerUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sd.db")
	defer c.Close()
	err := c.SetDisappearingTimer("1234@g.us", 86400)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetDisappearingTimerBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sd2.db")
	defer c.Close()
	err := c.SetDisappearingTimer("not a jid", 86400)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestSetGroupAnnounceUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sga.db")
	defer c.Close()
	err := c.SetGroupAnnounce("1234@g.us", true)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupAnnounceBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sga2.db")
	defer c.Close()
	err := c.SetGroupAnnounce("not a jid", true)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestSetGroupLockedUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sgl.db")
	defer c.Close()
	err := c.SetGroupLocked("1234@g.us", true)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestSetGroupLockedBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sgl2.db")
	defer c.Close()
	err := c.SetGroupLocked("not a jid", true)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestMapGroupInfoCarriesEphemeralExpiration(t *testing.T) {
	in := &types.GroupInfo{
		JID:       types.NewJID("999", "g.us"),
		GroupName: types.GroupName{Name: "T"},
		GroupEphemeral: types.GroupEphemeral{
			IsEphemeral:       true,
			DisappearingTimer: 86400,
		},
	}
	got := mapGroupInfo(in)
	if got.EphemeralExpirationSeconds != 86400 {
		t.Fatalf("want 86400 got %d", got.EphemeralExpirationSeconds)
	}
}

func TestMapGroupInfoCarriesAnnounceLocked(t *testing.T) {
	in := &types.GroupInfo{
		JID:           types.NewJID("999", "g.us"),
		GroupName:     types.GroupName{Name: "T"},
		GroupAnnounce: types.GroupAnnounce{IsAnnounce: true},
		GroupLocked:   types.GroupLocked{IsLocked: true},
	}
	got := mapGroupInfo(in)
	if !got.IsAnnounce {
		t.Fatalf("want IsAnnounce true, got %+v", got)
	}
	if !got.IsLocked {
		t.Fatalf("want IsLocked true, got %+v", got)
	}
}
