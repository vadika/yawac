package bridge

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// applyHistorySync persists push names + contact display names from a
// HistorySync blob, and emits a synthetic "Message" event for every
// historical message it contains. This is what makes the Swift app
// show past conversations + contact names after pairing.
func (c *Client) applyHistorySync(evt *events.HistorySync) {
	if evt == nil || evt.Data == nil {
		return
	}
	ctx := context.Background()

	// Push names — persist to local contact store so listContacts() picks them up.
	if c.wa != nil && c.wa.Store != nil && c.wa.Store.Contacts != nil {
		for _, pn := range evt.Data.GetPushnames() {
			jidStr := pn.GetID()
			name := pn.GetPushname()
			if jidStr == "" || name == "" {
				continue
			}
			jid, err := types.ParseJID(jidStr)
			if err != nil {
				continue
			}
			_, _, _ = c.wa.Store.Contacts.PutPushName(ctx, jid, name)
		}
	}

	// Conversations — names + message backfill.
	for _, conv := range evt.Data.GetConversations() {
		chatJIDStr := conv.GetID()
		if chatJIDStr == "" {
			continue
		}
		chatJID, err := types.ParseJID(chatJIDStr)
		if err != nil {
			continue
		}
		// For 1:1 conversations, the Name field is the contact's display name.
		// PutContactName signature: (ctx, jid, fullName, firstName).
		if name := conv.GetName(); name != "" &&
			c.wa != nil && c.wa.Store != nil && c.wa.Store.Contacts != nil {
			_ = c.wa.Store.Contacts.PutContactName(ctx, chatJID, name, "")
		}

		// Two-pass: store every message's secret first so subsequent vote
		// decryption can find creation-message keys regardless of iteration
		// order in this HistorySync chunk.
		if c.wa != nil && c.wa.Store != nil && c.wa.Store.MsgSecrets != nil {
			for _, m := range conv.GetMessages() {
				wm := m.GetMessage()
				if wm == nil {
					continue
				}
				secret := wm.GetMessageSecret()
				if len(secret) == 0 {
					continue
				}
				key := wm.GetKey()
				if key == nil {
					continue
				}
				senderStr := key.GetParticipant()
				if senderStr == "" {
					if key.GetFromMe() && c.wa.Store.ID != nil {
						senderStr = c.wa.Store.ID.String()
					} else {
						senderStr = chatJIDStr
					}
				}
				sender, err := types.ParseJID(senderStr)
				if err != nil {
					continue
				}
				_ = c.wa.Store.MsgSecrets.PutMessageSecret(
					ctx, chatJID, sender, key.GetID(), secret)
			}
		}

		for _, m := range conv.GetMessages() {
			wm := m.GetMessage()
			if wm == nil {
				continue
			}
			c.dispatchWebMessage(chatJIDStr, wm)
		}
	}
}

// dispatchWebMessage converts a WebMessageInfo (from history sync)
// into the same JMessage JSON shape that dispatchMessage emits.
func (c *Client) dispatchWebMessage(chatJID string, wm *waWeb.WebMessageInfo) {
	key := wm.GetKey()
	if key == nil {
		return
	}
	msg := wm.GetMessage()
	if msg == nil {
		return
	}
	senderJID := chatJID
	if p := key.GetParticipant(); p != "" {
		senderJID = p
	} else if key.GetFromMe() {
		// Best effort: own JID is not on the key for from-me messages.
		if c.wa != nil && c.wa.Store != nil && c.wa.Store.ID != nil {
			senderJID = c.wa.Store.ID.String()
		}
	}

	// Note: per-message MessageSecret is persisted by applyHistorySync's
	// two-pass loop above so vote decryption can find any creation key
	// regardless of HistorySync iteration order.
	if r := msg.GetReactionMessage(); r != nil {
		fmt.Fprintf(os.Stderr,
			"[yawac/reaction-history] chat=%s sender=%s target=%s\n",
			chatJID, senderJID, r.GetKey().GetID())
		c.dispatchReaction(chatJID, senderJID, int64(wm.GetMessageTimestamp()), r)
		return
	}
	// Community-announcement encrypted reactions in historical backfills.
	// DecryptReaction needs a real *events.Message; build one via
	// ParseWebMessage. We've never actually observed HistorySync ship
	// these (mirrors the plain reaction case — see docs/TODO.md
	// "Historical reactions — unrecoverable") but the path is here for
	// when the protocol changes.
	if msg.GetEncReactionMessage() != nil {
		chat, perr := types.ParseJID(chatJID)
		if perr != nil {
			return
		}
		evt, perr := c.wa.ParseWebMessage(chat, wm)
		if perr != nil || evt == nil {
			return
		}
		decrypted, err := c.wa.DecryptReaction(context.Background(), evt)
		if err == nil && decrypted != nil {
			c.dispatchReaction(chatJID, senderJID, int64(wm.GetMessageTimestamp()), decrypted)
		} else {
			fmt.Fprintf(os.Stderr,
				"[yawac/enc-reaction-history] decrypt fail chat=%s sender=%s err=%v\n",
				chatJID, senderJID, err)
		}
		return
	}
	if msg.GetPollUpdateMessage() != nil {
		// HistorySync rarely (currently never observed) ships vote events,
		// but if one arrives we try to decrypt + dispatch it. The creation's
		// MessageSecret was already persisted in the two-pass above so the
		// per-poll cipher key is available regardless of iteration order.
		// See docs/TODO.md "Historical poll vote tallies — unrecoverable".
		if chat, err := types.ParseJID(chatJID); err == nil {
			if evt, err := c.wa.ParseWebMessage(chat, wm); err == nil {
				c.dispatchPollVote(evt)
			}
		}
		return
	}
	kind := classifyMessage(msg)
	if kind == "protocol" || kind == "system" {
		return // skip noise
	}
	jm := JMessage{
		ID:             key.GetID(),
		ChatJID:        chatJID,
		SenderJID:      senderJID,
		SenderPushName: wm.GetPushName(),
		FromMe:         key.GetFromMe(),
		Timestamp:      int64(wm.GetMessageTimestamp()),
		Kind:           kind,
	}
	switch {
	case msg.GetConversation() != "":
		jm.Text = msg.GetConversation()
	case msg.GetExtendedTextMessage() != nil:
		jm.Text = msg.GetExtendedTextMessage().GetText()
	}
	if im := msg.GetImageMessage(); im != nil {
		jm.Media = mediaFromImage(im)
	} else if vm := msg.GetVideoMessage(); vm != nil {
		jm.Media = mediaFromVideo(vm)
	} else if am := msg.GetAudioMessage(); am != nil {
		jm.Media = mediaFromAudio(am)
	} else if dm := msg.GetDocumentMessage(); dm != nil {
		jm.Media = mediaFromDocument(dm)
	} else if sm := msg.GetStickerMessage(); sm != nil {
		jm.Media = mediaFromSticker(sm)
	}
	if p := extractPoll(msg); p != nil {
		jm.Poll = p
	}
	b, _ := json.Marshal(jm)
	c.dispatch("Message", string(b))

	// Historical poll-vote tallies. WebMessageInfo.pollUpdates is the
	// primary phone's bundled-up record of all PollUpdate (vote)
	// messages that landed on the poll *before* this companion paired.
	// Each entry has the already-decrypted PollVoteMessage (raw SHA-256
	// option hashes) plus the voter's JID on the update's MessageKey.
	// whatsmeow defines the proto field but never consumes it — patch
	// that gap here so on first sync we can render past tallies that
	// the official client shows but our companion otherwise can't see.
	if isPollCreation(msg) {
		c.emitHistoricalPollUpdates(chatJID, key.GetID(), wm)
	}
}

// emitHistoricalPollUpdates surfaces the embedded historical vote
// records on a WebMessageInfo (poll-creation message) by dispatching
// one synthetic "PollVote" event per voter. Hashes are already in
// SHA-256-of-option-name form, matching what dispatchPollVote emits
// from live events, so the Swift tallying path is identical.
func (c *Client) emitHistoricalPollUpdates(chatJID, pollMsgID string, wm *waWeb.WebMessageInfo) {
	updates := wm.GetPollUpdates()
	if len(updates) == 0 {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/poll-history] chat=%s poll=%s nUpdates=%d\n",
		chatJID, pollMsgID, len(updates))
	for _, pu := range updates {
		vote := pu.GetVote()
		if vote == nil {
			continue
		}
		voteKey := pu.GetPollUpdateMessageKey()
		voterJID := ""
		var voteTS int64
		if voteKey != nil {
			if p := voteKey.GetParticipant(); p != "" {
				voterJID = p
			} else if voteKey.GetFromMe() &&
				c.wa != nil && c.wa.Store != nil && c.wa.Store.ID != nil {
				voterJID = c.wa.Store.ID.ToNonAD().String()
			} else {
				// 1:1 polls have no participant on the key; voter is
				// the chat peer (or us if fromMe).
				voterJID = chatJID
			}
		}
		if ts := pu.GetSenderTimestampMS(); ts > 0 {
			voteTS = ts / 1000
		} else {
			voteTS = int64(wm.GetMessageTimestamp())
		}
		hashes := make([]string, 0, len(vote.GetSelectedOptions()))
		for _, h := range vote.GetSelectedOptions() {
			hashes = append(hashes, hex.EncodeToString(h))
		}
		payload := JPollVote{
			ChatJID:       chatJID,
			PollMessageID: pollMsgID,
			VoterJID:      voterJID,
			OptionHashes:  hashes,
			Timestamp:     voteTS,
		}
		b, _ := json.Marshal(payload)
		c.dispatch("PollVote", string(b))
	}
}
