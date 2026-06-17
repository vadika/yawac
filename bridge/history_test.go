package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	waHistoryPb "go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func TestDispatchHistoryEmpty(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/h.db")
	defer c.Close()
	sink := newRecSink()
	c.SetEventSink(sink)

	syncType := waHistoryPb.HistorySync_FULL
	h := &events.HistorySync{Data: &waHistoryPb.HistorySync{SyncType: &syncType}}
	c.dispatchHistory(h)

	e := sink.wait(t, "HistorySync", time.Second)
	var m map[string]any
	if err := json.Unmarshal([]byte(e.payload), &m); err != nil {
		t.Fatal(err)
	}
	if m["sync_type"] != "FULL" {
		t.Fatalf("want FULL, got %v", m["sync_type"])
	}
}

func TestHistoricalRecordToVote(t *testing.T) {
	ownJID := "5550100@s.whatsapp.net"
	peerJID, err := types.ParseJID("5550200@s.whatsapp.net")
	if err != nil {
		t.Fatalf("parse peer: %v", err)
	}
	groupJID, err := types.ParseJID("12345-67890@g.us")
	if err != nil {
		t.Fatalf("parse group: %v", err)
	}
	participantJID, err := types.ParseJID("5550300@s.whatsapp.net")
	if err != nil {
		t.Fatalf("parse participant: %v", err)
	}

	mkHash := func(s string) []byte {
		sum := sha256.Sum256([]byte(s))
		return sum[:]
	}

	cases := []struct {
		name           string
		record         events.HistoricalPollVote
		expectedVoter  string
		expectedChat   string
		expectedHashes []string
	}{
		{
			name: "own vote on own poll",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P1",
				Voter:                types.JID{},
				SelectedOptionHashes: [][]byte{mkHash("A")},
				Timestamp:            time.Unix(1729000000, 0),
				PollCreationFromMe:   true,
			},
			expectedVoter:  ownJID,
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("A"))},
		},
		{
			name: "own vote on peer poll (F88 regression guard)",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P2",
				Voter:                types.JID{},
				SelectedOptionHashes: [][]byte{mkHash("B")},
				Timestamp:            time.Unix(1729000001, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter:  ownJID,
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("B"))},
		},
		{
			name: "peer vote on peer poll 1:1",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P3",
				Voter:                peerJID,
				SelectedOptionHashes: [][]byte{mkHash("C")},
				Timestamp:            time.Unix(1729000002, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter:  peerJID.String(),
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("C"))},
		},
		{
			name: "peer vote on own poll 1:1",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P4",
				Voter:                peerJID,
				SelectedOptionHashes: [][]byte{mkHash("D")},
				Timestamp:            time.Unix(1729000003, 0),
				PollCreationFromMe:   true,
			},
			expectedVoter:  peerJID.String(),
			expectedChat:   peerJID.String(),
			expectedHashes: []string{hex.EncodeToString(mkHash("D"))},
		},
		{
			name: "peer vote in group",
			record: events.HistoricalPollVote{
				Chat:                 groupJID,
				PollCreationID:       "P5",
				Voter:                participantJID,
				SelectedOptionHashes: [][]byte{mkHash("E"), mkHash("F")},
				Timestamp:            time.Unix(1729000004, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter: participantJID.String(),
			expectedChat:  groupJID.String(),
			expectedHashes: []string{
				hex.EncodeToString(mkHash("E")),
				hex.EncodeToString(mkHash("F")),
			},
		},
		{
			name: "empty selection (vote clear)",
			record: events.HistoricalPollVote{
				Chat:                 peerJID,
				PollCreationID:       "P6",
				Voter:                peerJID,
				SelectedOptionHashes: nil,
				Timestamp:            time.Unix(1729000005, 0),
				PollCreationFromMe:   false,
			},
			expectedVoter:  peerJID.String(),
			expectedChat:   peerJID.String(),
			expectedHashes: []string{},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := historicalRecordToVote(tc.record, ownJID)
			if got.VoterJID != tc.expectedVoter {
				t.Errorf("VoterJID = %q, want %q", got.VoterJID, tc.expectedVoter)
			}
			if got.ChatJID != tc.expectedChat {
				t.Errorf("ChatJID = %q, want %q", got.ChatJID, tc.expectedChat)
			}
			if got.PollMessageID != string(tc.record.PollCreationID) {
				t.Errorf("PollMessageID = %q, want %q",
					got.PollMessageID, tc.record.PollCreationID)
			}
			if got.Timestamp != tc.record.Timestamp.Unix() {
				t.Errorf("Timestamp = %d, want %d",
					got.Timestamp, tc.record.Timestamp.Unix())
			}
			if len(got.OptionHashes) != len(tc.expectedHashes) {
				t.Fatalf("OptionHashes len = %d, want %d",
					len(got.OptionHashes), len(tc.expectedHashes))
			}
			for i, h := range got.OptionHashes {
				if h != tc.expectedHashes[i] {
					t.Errorf("OptionHashes[%d] = %q, want %q",
						i, h, tc.expectedHashes[i])
				}
			}
		})
	}
}

func TestHistoricalRecordToVoteUnpaired(t *testing.T) {
	// Empty ownBareJID (client not paired): empty Voter must stay empty,
	// not crash, not pick up a stray string.
	record := events.HistoricalPollVote{
		Chat:                 types.JID{User: "x", Server: types.DefaultUserServer},
		PollCreationID:       "P",
		Voter:                types.JID{},
		SelectedOptionHashes: [][]byte{{0xab}},
		Timestamp:            time.Unix(1, 0),
		PollCreationFromMe:   true,
	}
	got := historicalRecordToVote(record, "")
	if got.VoterJID != "" {
		t.Errorf("unpaired VoterJID = %q, want empty", got.VoterJID)
	}
	if len(got.OptionHashes) != 1 || got.OptionHashes[0] != "ab" {
		t.Errorf("OptionHashes = %v, want [ab]", got.OptionHashes)
	}
}
