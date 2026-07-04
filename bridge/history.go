package bridge

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// HistoricalPollVote is one poll-vote record extracted from a HistorySync
// blob's WebMessageInfo.PollUpdates arrays. Moved here from fork PR #1151
// so the whatsmeow fork carries one fewer patch — the extraction only
// touches public whatsmeow API. SelectedOptionHashes are SHA-256(option)
// digests matching what Client.DecryptPollVote emits for live votes, so
// the Swift tally path is uniform across live and historical sources.
type HistoricalPollVote struct {
	Chat                 types.JID
	PollCreationID       types.MessageID
	Voter                types.JID
	SelectedOptionHashes [][]byte
	Timestamp            time.Time
	PollCreationFromMe   bool
}

// historicalPollUpdates flattens every previously-bundled poll-vote
// record in a HistorySync blob. Empty Voter on 1:1 polls means own-vote;
// the caller substitutes ownBareJID. Returns nil when the blob has none.
func historicalPollUpdates(h *events.HistorySync) []HistoricalPollVote {
	if h == nil || h.Data == nil {
		return nil
	}
	var out []HistoricalPollVote
	for _, conv := range h.Data.GetConversations() {
		chatJIDStr := conv.GetID()
		if chatJIDStr == "" {
			continue
		}
		chatJID, err := types.ParseJID(chatJIDStr)
		if err != nil {
			continue
		}
		for _, m := range conv.GetMessages() {
			wm := m.GetMessage()
			if wm == nil {
				continue
			}
			updates := wm.GetPollUpdates()
			if len(updates) == 0 {
				continue
			}
			key := wm.GetKey()
			if key == nil {
				continue
			}
			pollID := types.MessageID(key.GetID())
			pollFromMe := key.GetFromMe()
			for _, pu := range updates {
				vote := pu.GetVote()
				if vote == nil {
					continue
				}
				var voter types.JID
				if voteKey := pu.GetPollUpdateMessageKey(); voteKey != nil {
					if p := voteKey.GetParticipant(); p != "" {
						if vj, perr := types.ParseJID(p); perr == nil {
							voter = vj
						}
					} else if !voteKey.GetFromMe() {
						voter = chatJID
					}
				}
				ts := time.Unix(int64(wm.GetMessageTimestamp()), 0)
				if ms := pu.GetSenderTimestampMS(); ms > 0 {
					ts = time.UnixMilli(ms)
				}
				out = append(out, HistoricalPollVote{
					Chat:                 chatJID,
					PollCreationID:       pollID,
					Voter:                voter,
					SelectedOptionHashes: vote.GetSelectedOptions(),
					Timestamp:            ts,
					PollCreationFromMe:   pollFromMe,
				})
			}
		}
	}
	return out
}

// applyHistorySync persists push names + contact display names from a
// HistorySync blob, and emits a synthetic "Message" event for every
// historical message it contains. This is what makes the Swift app
// show past conversations + contact names after pairing.
func (c *Client) applyHistorySync(evt *events.HistorySync) {
	if evt == nil || evt.Data == nil {
		return
	}
	ctx := context.Background()

	// Push names — persist to local contact store so listContacts() picks
	// them up, AND emit one batched "push_names" event so Swift can key
	// contactNames at the exact JID form the server shipped (typically
	// `@lid` for group senders whose LID→PN map entry is missing).
	// PutPushName normalizes to `@s.whatsapp.net`, which is why the Swift
	// `displayName(for:)` lookup at the bare `@lid` key still misses for
	// those senders — see project_yawac_lid_push_name notes.
	pushBatch := make([]JPushName, 0, len(evt.Data.GetPushnames()))
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
			pushBatch = append(pushBatch, JPushName{JID: jidStr, Name: name})
			_, _, _ = c.wa.Store.Contacts.PutPushName(ctx, jid, name)
		}
	}
	if len(pushBatch) > 0 {
		b, _ := json.Marshal(JPushNameBatch{Names: pushBatch})
		c.dispatch("push_names", string(b))
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

	// Surface every poll's bundled historical vote tally in one sweep.
	// Helper added upstream — see tulir/whatsmeow PR #1151 — which
	// flattens WebMessageInfo.PollUpdates across the whole blob so we
	// don't have to walk it per-message ourselves.
	c.emitHistoricalPollUpdatesFromBlob(evt)
}

// emitHistoricalPollUpdatesFromBlob dispatches one synthetic "PollVote"
// event per record returned by events.HistorySync.HistoricalPollUpdates().
// The fork's helper already produces SHA-256(optionName) hashes —
// identical to what DecryptPollVote yields for live votes — so the
// Swift tally path is uniform across live and historical sources.
//
// F90: per-sweep counter log so /tmp/yawac.log shows substitution
// activity after a Full sync. self > 0 confirms the empty-voter →
// ownJID substitution fired (fix for the F88 PollCreationFromMe gate
// that missed own-votes on peer-created polls).
func (c *Client) emitHistoricalPollUpdatesFromBlob(evt *events.HistorySync) {
	records := historicalPollUpdates(evt)
	if len(records) == 0 {
		return
	}
	var ownBareJID string
	if c.wa != nil && c.wa.Store != nil && c.wa.Store.ID != nil {
		ownBareJID = c.wa.Store.ID.ToNonAD().String()
	}
	var selfN, peerN int
	for _, r := range records {
		v := historicalRecordToVote(r, ownBareJID)
		if ownBareJID != "" && v.VoterJID == ownBareJID {
			selfN++
		} else {
			peerN++
		}
		b, _ := json.Marshal(v)
		c.dispatch("PollVote", string(b))
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/poll-history] sweep records=%d self=%d peer=%d\n",
		len(records), selfN, peerN)
}

// historicalRecordToVote maps one HistoricalPollVote record into the
// JPollVote payload that mirrors live PollUpdateMessage dispatches.
// Empty r.Voter signals an own-vote: the upstream helper (fork PR
// #1151's HistoricalPollUpdates) sets Voter only when
// PollUpdateMessageKey.Participant is set, OR when the chat is 1:1 and
// the vote is NOT from us; when voteKey.FromMe is true it leaves Voter
// empty. The only consistent interpretation is "vote from us", so
// substitute ownBareJID. Swift's mySelections() keys against
// client.ownJID (= Store.ID.ToNonAD().String()) so the substitution form
// must match.
//
// When the client is unpaired (ownBareJID == ""), the substitution is
// skipped — VoterJID stays empty and SQLite upsert is recoverable on
// the next sweep after pairing.
func historicalRecordToVote(r HistoricalPollVote, ownBareJID string) JPollVote {
	voterStr := r.Voter.String()
	if voterStr == "" && ownBareJID != "" {
		voterStr = ownBareJID
	}
	hashes := make([]string, 0, len(r.SelectedOptionHashes))
	for _, h := range r.SelectedOptionHashes {
		hashes = append(hashes, hex.EncodeToString(h))
	}
	return JPollVote{
		ChatJID:       r.Chat.String(),
		PollMessageID: string(r.PollCreationID),
		VoterJID:      voterStr,
		OptionHashes:  hashes,
		Timestamp:     r.Timestamp.Unix(),
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
	// Hydrate the 1:1 disappearing-messages timer opportunistically from
	// the historical message's ContextInfo.Expiration. Same rationale as
	// dispatchMessage: whatsmeow populates this on every regular message
	// in a disappearing chat, and history sync is often the first time
	// yawac sees the chat.
	if exp := extractContextInfoExpiration(msg); exp > 0 {
		b, _ := json.Marshal(JEphemeralTimerChanged{
			ChatJID:   chatJID,
			Seconds:   int32(exp),
			Timestamp: int64(wm.GetMessageTimestamp()),
		})
		c.dispatch("EphemeralTimerChanged", string(b))
	}
	kind, loc, locSeq, contact, isViewOnce := classifyMessage(msg)
	// F35: surface historical EPHEMERAL_SETTING toggles as inline
	// system rows (same as the live dispatchMessage path does for
	// newly-arrived ones). The carrier itself still gets dropped
	// below by the protocol-skip — this just adds the human-visible
	// shadow row.
	if pm := msg.GetProtocolMessage(); pm != nil &&
		pm.GetType() == waE2E.ProtocolMessage_EPHEMERAL_SETTING {
		c.dispatchEphemeralSystemRow(
			chatJID, senderJID,
			int32(pm.GetEphemeralExpiration()),
			int64(wm.GetMessageTimestamp()))
	}
	if kind == "protocol" || kind == "system" {
		return // skip noise
	}
	jm := JMessage{
		ID:               key.GetID(),
		ChatJID:          chatJID,
		SenderJID:        senderJID,
		SenderPushName:   wm.GetPushName(),
		FromMe:           key.GetFromMe(),
		Timestamp:        int64(wm.GetMessageTimestamp()),
		Kind:             kind,
		Location:         loc,
		LocationSequence: locSeq,
		Contact:          contact,
		IsViewOnce:       isViewOnce,
	}
	inner := unwrapViewOnce(msg)
	switch {
	case inner.GetConversation() != "":
		jm.Text = inner.GetConversation()
	case inner.GetExtendedTextMessage() != nil:
		jm.Text = inner.GetExtendedTextMessage().GetText()
	case inner.GetInteractiveMessage() != nil,
		inner.GetInteractiveResponseMessage() != nil,
		inner.GetTemplateMessage() != nil,
		inner.GetTemplateButtonReplyMessage() != nil,
		inner.GetButtonsMessage() != nil,
		inner.GetButtonsResponseMessage() != nil,
		inner.GetListMessage() != nil,
		inner.GetListResponseMessage() != nil,
		inner.GetOrderMessage() != nil,
		inner.GetProductMessage() != nil,
		inner.GetHighlyStructuredMessage() != nil:
		jm.Text = bestEffortBusinessText(inner)
	}
	if ctx := contextInfoFromMessage(inner); ctx != nil && ctx.GetStanzaID() != "" {
		qKind, _, _, _, _ := classifyMessage(ctx.GetQuotedMessage())
		jm.Quoted = &JQuoted{
			MessageID: ctx.GetStanzaID(),
			SenderJID: ctx.GetParticipant(),
			FromMe:    isFromMe(c, ctx.GetParticipant()),
			Kind:      qKind,
			Snippet:   extractSnippet(ctx.GetQuotedMessage()),
		}
	}
	if im := inner.GetImageMessage(); im != nil {
		jm.Media = mediaFromImage(im)
	} else if vm := inner.GetVideoMessage(); vm != nil {
		jm.Media = mediaFromVideo(vm)
	} else if am := inner.GetAudioMessage(); am != nil {
		jm.Media = mediaFromAudio(am)
	} else if dm := inner.GetDocumentMessage(); dm != nil {
		jm.Media = mediaFromDocument(dm)
	} else if sm := inner.GetStickerMessage(); sm != nil {
		jm.Media = mediaFromSticker(sm)
	}
	if p := extractPoll(inner); p != nil {
		jm.Poll = p
	}
	b, _ := json.Marshal(jm)
	c.dispatch("Message", string(b))
	// Historical poll tallies are now surfaced once per HistorySync blob
	// via emitHistoricalPollUpdatesFromBlob (called from applyHistorySync).
}
