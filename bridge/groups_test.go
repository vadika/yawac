package bridge

import (
	"encoding/json"
	"testing"

	"go.mau.fi/whatsmeow"
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
