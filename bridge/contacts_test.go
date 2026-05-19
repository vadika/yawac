package bridge

import (
	"encoding/json"
	"testing"
)

func TestListContactsReturnsArray(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	s, err := c.ListContacts()
	if err != nil {
		t.Skipf("ListContacts on unpaired client: %v", err)
	}
	var arr []JContact
	if err := json.Unmarshal([]byte(s), &arr); err != nil {
		t.Fatalf("decode: %v (%s)", err, s)
	}
}
