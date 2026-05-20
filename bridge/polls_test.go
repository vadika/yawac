package bridge

import (
	"crypto/sha256"
	"encoding/hex"
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
