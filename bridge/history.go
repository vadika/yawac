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

	// Surface every poll's bundled historical vote tally in one sweep.
	// Helper added upstream — see tulir/whatsmeow PR #1151 — which
	// flattens WebMessageInfo.PollUpdates across the whole blob so we
	// don't have to walk it per-message ourselves.
	c.emitHistoricalPollUpdatesFromBlob(evt)
}

// emitHistoricalPollUpdatesFromBlob dispatches one synthetic "PollVote"
// event per record returned by events.HistorySync.HistoricalPollUpdates().
// The helper already produces SHA-256(optionName) hashes — identical to
// what DecryptPollVote yields for live votes — so the Swift tally path
// is uniform across live and historical sources.
func (c *Client) emitHistoricalPollUpdatesFromBlob(evt *events.HistorySync) {
	records := evt.HistoricalPollUpdates()
	if len(records) == 0 {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/poll-history] sweep %d records\n", len(records))
	for _, r := range records {
		voterStr := r.Voter.String()
		// Self-vote: helper leaves Voter empty when the update key has
		// FromMe=true and no Participant. Substitute our own bare JID
		// so the Swift side keys this against client.ownJID.
		if voterStr == "" && r.PollCreationFromMe &&
			c.wa != nil && c.wa.Store != nil && c.wa.Store.ID != nil {
			voterStr = c.wa.Store.ID.ToNonAD().String()
		}
		hashes := make([]string, 0, len(r.SelectedOptionHashes))
		for _, h := range r.SelectedOptionHashes {
			hashes = append(hashes, hex.EncodeToString(h))
		}
		payload := JPollVote{
			ChatJID:       r.Chat.String(),
			PollMessageID: r.PollCreationID,
			VoterJID:      voterStr,
			OptionHashes:  hashes,
			Timestamp:     r.Timestamp.Unix(),
		}
		b, _ := json.Marshal(payload)
		c.dispatch("PollVote", string(b))
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
