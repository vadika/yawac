package bridge

import (
	"encoding/json"
	"strings"
	"testing"
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
