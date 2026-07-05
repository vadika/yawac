package bridge

import (
	"strings"
	"testing"
)

// Guard + parse error paths only; the happy path needs a live socket
// and is covered by manual empirical verification.
// All cases use a bare &Client{} — the implementation parses JIDs
// BEFORE the nil-client guard precisely so these tests need no store.
func TestRequestMessageResendErrors(t *testing.T) {
	cases := []struct {
		name         string
		chat, sender string
		wantSubstr   string
	}{
		{"bad chat jid", "1:bad@g.us", "456@lid", "chat jid"},
		{"bad sender jid", "123@g.us", "1:bad@lid", "sender jid"},
		{"closed client", "123@g.us", "456@lid", "client closed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &Client{} // c.wa == nil
			err := c.RequestMessageResend(tc.chat, tc.sender, "ABC123")
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.wantSubstr)
			}
			if !strings.Contains(err.Error(), tc.wantSubstr) {
				t.Fatalf("want error containing %q, got %q", tc.wantSubstr, err.Error())
			}
		})
	}
}
