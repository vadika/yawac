package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func newPollMessage() *waE2E.Message {
	return &waE2E.Message{
		PollCreationMessage: &waE2E.PollCreationMessage{
			Name:                   proto.String("Lunch?"),
			SelectableOptionsCount: proto.Uint32(1),
			Options: []*waE2E.PollCreationMessage_Option{
				{OptionName: proto.String("Pizza")},
				{OptionName: proto.String("Sushi")},
			},
		},
	}
}

func TestExtractPollV1(t *testing.T) {
	jp := extractPoll(newPollMessage())
	if jp == nil {
		t.Fatal("expected poll, got nil")
	}
	if jp.Question != "Lunch?" {
		t.Fatalf("question: got %q", jp.Question)
	}
	if jp.SelectableCount != 1 {
		t.Fatalf("selectable: got %d", jp.SelectableCount)
	}
	if len(jp.Options) != 2 {
		t.Fatalf("options: got %d", len(jp.Options))
	}
	expectedHash := func(name string) string {
		sum := sha256.Sum256([]byte(name))
		return hex.EncodeToString(sum[:])
	}
	if jp.Options[0].Name != "Pizza" || jp.Options[0].Hash != expectedHash("Pizza") {
		t.Fatalf("first option: %+v", jp.Options[0])
	}
	if jp.Options[1].Name != "Sushi" || jp.Options[1].Hash != expectedHash("Sushi") {
		t.Fatalf("second option: %+v", jp.Options[1])
	}
}

func TestExtractPollV2V3V5V6(t *testing.T) {
	mk := func() *waE2E.PollCreationMessage {
		return &waE2E.PollCreationMessage{
			Name:                   proto.String("Q"),
			SelectableOptionsCount: proto.Uint32(2),
			Options: []*waE2E.PollCreationMessage_Option{
				{OptionName: proto.String("A")},
			},
		}
	}
	for _, tc := range []struct {
		name string
		msg  *waE2E.Message
	}{
		{"V2", &waE2E.Message{PollCreationMessageV2: mk()}},
		{"V3", &waE2E.Message{PollCreationMessageV3: mk()}},
		{"V5", &waE2E.Message{PollCreationMessageV5: mk()}},
		{"V6", &waE2E.Message{PollCreationMessageV6: mk()}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			jp := extractPoll(tc.msg)
			if jp == nil || jp.Question != "Q" || jp.SelectableCount != 2 || len(jp.Options) != 1 {
				t.Fatalf("got %+v", jp)
			}
		})
	}
}

func TestExtractPollNilOnNonPoll(t *testing.T) {
	if extractPoll(&waE2E.Message{Conversation: proto.String("hi")}) != nil {
		t.Fatal("expected nil for text message")
	}
	if extractPoll(nil) != nil {
		t.Fatal("expected nil for nil message")
	}
}

func TestClassifyMessagePoll(t *testing.T) {
	if got := classifyMessage(newPollMessage()); got != "poll" {
		t.Fatalf("classifyMessage(poll) = %q, want poll", got)
	}
	pu := &waE2E.Message{PollUpdateMessage: &waE2E.PollUpdateMessage{}}
	if got := classifyMessage(pu); got != "poll_vote" {
		t.Fatalf("classifyMessage(poll_update) = %q, want poll_vote", got)
	}
}

func TestSendPollCreationRejectsBadJID(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pc1.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.SendPollCreation("not-a-jid", "Q",
		`["A","B"]`, 1)
	if err == nil || !strings.Contains(err.Error(), "jid") {
		t.Fatalf("want jid error, got %v", err)
	}
}

func TestSendPollCreationClosedClient(t *testing.T) {
	c := &Client{} // wa is nil
	_, err := c.SendPollCreation("12345@s.whatsapp.net", "Q",
		`["A","B"]`, 1)
	if err == nil {
		t.Fatal("expected error for closed client")
	}
}

func TestSendPollCreationRejectsTooFewOptions(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pc2.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
		`["only-one"]`, 1)
	if err == nil || !strings.Contains(err.Error(), "options") {
		t.Fatalf("want options error, got %v", err)
	}
}

func TestSendPollCreationRejectsTooManyOptions(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pc3.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	opts := `["1","2","3","4","5","6","7","8","9","10","11","12","13"]`
	_, err = c.SendPollCreation("12345@s.whatsapp.net", "Q", opts, 1)
	if err == nil || !strings.Contains(err.Error(), "options") {
		t.Fatalf("want options error, got %v", err)
	}
}

func TestSendPollCreationRejectsEmptyOption(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pc4.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
		`["A","   "]`, 1)
	if err == nil || !strings.Contains(err.Error(), "option") {
		t.Fatalf("want option error, got %v", err)
	}
}

func TestSendPollCreationRejectsEmptyQuestion(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pc5.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.SendPollCreation("12345@s.whatsapp.net", "   ",
		`["A","B"]`, 1)
	if err == nil || !strings.Contains(err.Error(), "question") {
		t.Fatalf("want question error, got %v", err)
	}
}

func TestSendPollCreationRejectsBadSelectableCount(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/pc6.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
		`["A","B"]`, -1)
	if err == nil || !strings.Contains(err.Error(), "selectable") {
		t.Fatalf("want selectable error for -1, got %v", err)
	}
	_, err = c.SendPollCreation("12345@s.whatsapp.net", "Q",
		`["A","B"]`, 3)
	if err == nil || !strings.Contains(err.Error(), "selectable") {
		t.Fatalf("want selectable error for >len, got %v", err)
	}
}
