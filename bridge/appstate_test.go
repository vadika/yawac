package bridge

import (
	"strings"
	"testing"
)

func TestMessageKeyOrNilEmptyID(t *testing.T) {
	if k := messageKeyOrNil("12345@s.whatsapp.net", "", false); k != nil {
		t.Fatalf("want nil for empty id, got %+v", k)
	}
}

func TestMessageKeyOrNilPopulated(t *testing.T) {
	k := messageKeyOrNil("12345@s.whatsapp.net", "MID1", true)
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
