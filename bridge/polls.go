package bridge

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// extractPoll returns a *JPoll if the message carries any of the known
// PollCreationMessage protobuf variants. Returns nil otherwise.
//
// whatsmeow exposes PollCreationMessage on fields named
// PollCreationMessage, PollCreationMessageV2, V3, V5, V6. V4 is a
// FutureProofMessage placeholder that we ignore (it has no concrete shape
// in this protobuf version).
func extractPoll(m *waE2E.Message) *JPoll {
	if m == nil {
		return nil
	}
	var src *waE2E.PollCreationMessage
	switch {
	case m.GetPollCreationMessage() != nil:
		src = m.GetPollCreationMessage()
	case m.GetPollCreationMessageV2() != nil:
		src = m.GetPollCreationMessageV2()
	case m.GetPollCreationMessageV3() != nil:
		src = m.GetPollCreationMessageV3()
	case m.GetPollCreationMessageV5() != nil:
		src = m.GetPollCreationMessageV5()
	case m.GetPollCreationMessageV6() != nil:
		src = m.GetPollCreationMessageV6()
	default:
		return nil
	}
	jp := &JPoll{
		Question:        src.GetName(),
		SelectableCount: int(src.GetSelectableOptionsCount()),
	}
	for _, o := range src.GetOptions() {
		name := o.GetOptionName()
		sum := sha256.Sum256([]byte(name))
		jp.Options = append(jp.Options, JPollOption{
			Name: name,
			Hash: hex.EncodeToString(sum[:]),
		})
	}
	return jp
}

// isPollCreation returns true if the Message carries any known
// PollCreationMessage variant.
func isPollCreation(m *waE2E.Message) bool {
	if m == nil {
		return false
	}
	return m.GetPollCreationMessage() != nil ||
		m.GetPollCreationMessageV2() != nil ||
		m.GetPollCreationMessageV3() != nil ||
		m.GetPollCreationMessageV5() != nil ||
		m.GetPollCreationMessageV6() != nil
}

// SendPollVote casts a vote on the given poll. selectedHashesJSON is a
// JSON array of hex-encoded SHA256(optionName) strings (as emitted in the
// JPollOption.Hash field). We resolve each hash back to its OptionName by
// looking up the original poll message's options — whatsmeow's
// BuildPollVote requires option *names*, not hashes.
//
// Args:
//   - chatJID:           the chat the poll was posted in
//   - pollMsgID:         message id of the original PollCreationMessage
//   - pollSenderJID:     sender JID of that creation message
//   - pollFromMe:        whether the original poll was sent by us
//   - selectedHashesJSON: JSON array of hex-encoded SHA256(optionName) strings
//   - pollOptionsJSON:   JSON array of JPollOption — used to resolve hash -> name
//   - ephemeralSec:      when >0, wrap the vote in EphemeralMessage so it
//                        inherits the chat's disappearing-message retention.
//
// Returns JSON of JSendResult.
func (c *Client) SendPollVote(chatJID, pollMsgID, pollSenderJID string, pollFromMe bool, selectedHashesJSON, pollOptionsJSON string, ephemeralSec int32) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	sender, err := types.ParseJID(pollSenderJID)
	if err != nil {
		return "", fmt.Errorf("parse sender: %w", err)
	}

	var hexHashes []string
	if err := json.Unmarshal([]byte(selectedHashesJSON), &hexHashes); err != nil {
		return "", fmt.Errorf("parse hashes: %w", err)
	}
	var opts []JPollOption
	if err := json.Unmarshal([]byte(pollOptionsJSON), &opts); err != nil {
		return "", fmt.Errorf("parse options: %w", err)
	}
	byHash := make(map[string]string, len(opts))
	for _, o := range opts {
		byHash[o.Hash] = o.Name
	}
	names := make([]string, 0, len(hexHashes))
	for _, h := range hexHashes {
		name, ok := byHash[h]
		if !ok {
			return "", fmt.Errorf("unknown option hash %q", h)
		}
		names = append(names, name)
	}

	info := &types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chat,
			Sender:   sender,
			IsFromMe: pollFromMe,
			IsGroup:  chat.Server == types.GroupServer,
		},
		ID: pollMsgID,
	}
	ctx := context.Background()
	inner, err := c.wa.BuildPollVote(ctx, info, names)
	if err != nil {
		return "", fmt.Errorf("build vote: %w", err)
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(ctx, chat, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{
		MessageID: resp.ID,
		Timestamp: resp.Timestamp.Unix(),
	})
	return string(out), nil
}

// dispatchPollVote decrypts an incoming PollUpdateMessage and emits a
// "PollVote" event with hex-encoded option-hashes. whatsmeow's
// DecryptPollVote needs the full *events.Message because it caches the
// vote-decryption key keyed off the poll-creation MessageKey.
func (c *Client) dispatchPollVote(evt *events.Message) {
	pu := evt.Message.GetPollUpdateMessage()
	if pu == nil {
		return
	}
	key := pu.GetPollCreationMessageKey()
	if key == nil {
		return
	}
	if c.wa == nil {
		return
	}
	decrypted, err := c.wa.DecryptPollVote(context.Background(), evt)
	if err != nil {
		// Vote decryption can fail when the original poll-creation
		// message's MsgSecret was never persisted locally (companion
		// not paired at the time, or history-sync truncation). Log so
		// the Swift side has visibility into how often this happens —
		// the UI silently misses tallies otherwise.
		fmt.Fprintf(os.Stderr,
			"[yawac/poll-vote] decrypt fail chat=%s sender=%s poll=%s err=%v\n",
			evt.Info.Chat.String(), evt.Info.Sender.String(), key.GetID(), err)
		return
	}
	hashes := make([]string, 0, len(decrypted.GetSelectedOptions()))
	for _, h := range decrypted.GetSelectedOptions() {
		hashes = append(hashes, hex.EncodeToString(h))
	}
	payload := JPollVote{
		ChatJID:       evt.Info.Chat.String(),
		PollMessageID: key.GetID(),
		VoterJID:      evt.Info.Sender.String(),
		OptionHashes:  hashes,
		Timestamp:     evt.Info.Timestamp.Unix(),
	}
	b, _ := json.Marshal(payload)
	c.dispatch("PollVote", string(b))
}

// SendPollCreation builds a poll creation message and sends it. optionsJSON
// is a JSON array of option-name strings. selectableCount must be in
// 0..len(options); 0 means multi-select (WhatsApp convention), 1 means
// single. When ephemeralSec > 0, wraps in EphemeralMessage so the poll
// inherits the chat's disappearing-message retention. Returns JSON of
// JSendPollResult.
//
// Validation is strict because whatsmeow.BuildPollCreation silently clamps
// an out-of-range selectableOptionCount to 0 (msgsecret.go:326), which
// would hide programmer errors.
func (c *Client) SendPollCreation(
	chatJID, question, optionsJSON string,
	selectableCount int32,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return "", fmt.Errorf("parse jid: %q is not a valid jid", chatJID)
	}

	var rawOpts []string
	if err := json.Unmarshal([]byte(optionsJSON), &rawOpts); err != nil {
		return "", fmt.Errorf("parse options: %w", err)
	}
	q := strings.TrimSpace(question)
	if q == "" {
		return "", errors.New("question is empty")
	}
	opts := make([]string, 0, len(rawOpts))
	for _, o := range rawOpts {
		t := strings.TrimSpace(o)
		if t == "" {
			return "", errors.New("option is empty")
		}
		opts = append(opts, t)
	}
	if len(opts) < 2 {
		return "", fmt.Errorf("options: want 2..12, got %d", len(opts))
	}
	if len(opts) > 12 {
		return "", fmt.Errorf("options: want 2..12, got %d", len(opts))
	}
	if selectableCount < 0 || int(selectableCount) > len(opts) {
		return "", fmt.Errorf("selectable count: want 0..%d, got %d",
			len(opts), selectableCount)
	}

	inner := c.wa.BuildPollCreation(q, opts, int(selectableCount))
	// extractPoll runs on the inner (unwrapped) message because the
	// PollCreationMessage* fields live on the immediate Message, not
	// inside any Ephemeral wrap envelope.
	jp := extractPoll(inner)
	if jp == nil {
		return "", errors.New("internal: built message is not a poll")
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		fmt.Fprintf(os.Stderr,
			"[yawac/poll-create] chat=%s opts=%d sel=%d err=%v\n",
			chatJID, len(opts), selectableCount, err)
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendPollResult{
		MessageID: resp.ID,
		Timestamp: resp.Timestamp.Unix(),
		Poll:      *jp,
	})
	return string(out), nil
}
