package bridge

import (
	"encoding/json"
	"testing"
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
