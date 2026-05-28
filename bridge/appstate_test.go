package bridge

import (
	"strings"
	"testing"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/types"
)

func TestMessageKeyOrNilEmptyID(t *testing.T) {
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	if k := messageKeyOrNil(jid, "", false); k != nil {
		t.Fatalf("want nil for empty id, got %+v", k)
	}
}

func TestMessageKeyOrNilPopulated(t *testing.T) {
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	k := messageKeyOrNil(jid, "MID1", true)
	if k == nil {
		t.Fatal("want non-nil key")
	}
	if k.GetRemoteJID() != "12345@s.whatsapp.net" || k.GetID() != "MID1" || !k.GetFromMe() {
		t.Fatalf("bad key: remote=%s id=%s fromMe=%v",
			k.GetRemoteJID(), k.GetID(), k.GetFromMe())
	}
}

func TestArchiveChatBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/a.db")
	defer c.Close()
	err := c.ArchiveChat("abc:def@x", true, 0, "", false)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestDeleteChatBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/d.db")
	defer c.Close()
	err := c.DeleteChat("abc:def@x", 0, "", false)
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}

func TestBuildContactPatchNoFirstName(t *testing.T) {
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	p := buildContactPatch(jid, "Alice Smith", "")
	if p.Type != appstate.WAPatchCriticalUnblockLow {
		t.Fatalf("type=%v want critical_unblock_low", p.Type)
	}
	if len(p.Mutations) != 1 {
		t.Fatalf("mutations=%d want 1", len(p.Mutations))
	}
	m := p.Mutations[0]
	if len(m.Index) != 2 || m.Index[0] != appstate.IndexContact || m.Index[1] != jid.String() {
		t.Fatalf("bad index %v", m.Index)
	}
	if m.Version != 2 {
		t.Fatalf("version=%d want 2", m.Version)
	}
	ca := m.Value.GetContactAction()
	if ca.GetFullName() != "Alice Smith" || ca.GetFirstName() != "" || !ca.GetSaveOnPrimaryAddressbook() {
		t.Fatalf("bad action %+v", ca)
	}
}

func TestBuildContactPatchWithFirstName(t *testing.T) {
	jid, _ := types.ParseJID("12345@s.whatsapp.net")
	p := buildContactPatch(jid, "Alice Smith", "Alice")
	if p.Mutations[0].Value.GetContactAction().GetFirstName() != "Alice" {
		t.Fatal("first name not set")
	}
}

func TestSetContactNameBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	err := c.SetContactName("abc:def@x", "X", "")
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("got %v, want parse error", err)
	}
}
