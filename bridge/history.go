package bridge

import (
	"context"
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
		var pollCreates, pollVotes, withSecret int
		if c.wa != nil && c.wa.Store != nil && c.wa.Store.MsgSecrets != nil {
			for _, m := range conv.GetMessages() {
				wm := m.GetMessage()
				if wm == nil {
					continue
				}
				if mb := wm.GetMessage(); mb != nil {
					if isPollCreation(mb) { pollCreates++ }
					if mb.GetPollUpdateMessage() != nil { pollVotes++ }
				}
				secret := wm.GetMessageSecret()
				if len(secret) == 0 {
					continue
				}
				withSecret++
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

		if pollCreates+pollVotes > 0 {
			fmt.Fprintf(os.Stderr,
				"[yawac/poll-history] conv=%s polls=%d votes=%d with_secret=%d total_msgs=%d\n",
				chatJIDStr, pollCreates, pollVotes, withSecret, len(conv.GetMessages()))
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
		c.dispatchReaction(chatJID, senderJID, int64(wm.GetMessageTimestamp()), r)
		return
	}
	if msg.GetPollUpdateMessage() != nil {
		fmt.Fprintf(os.Stderr,
			"[yawac/poll-history] vote seen chat=%s id=%s from=%s\n",
			chatJID, key.GetID(), senderJID)
		if chat, err := types.ParseJID(chatJID); err == nil {
			if evt, err := c.wa.ParseWebMessage(chat, wm); err == nil {
				c.dispatchPollVote(evt)
			} else {
				fmt.Fprintf(os.Stderr,
					"[yawac/poll-history] ParseWebMessage fail chat=%s id=%s err=%v\n",
					chatJID, key.GetID(), err)
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
}
