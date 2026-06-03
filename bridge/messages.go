package bridge

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// wrapForChat optionally wraps inner in ViewOnceMessageV2 and then
// EphemeralMessage. ViewOnce wrap is only meaningful for
// ImageMessage / VideoMessage; the UI gates other kinds, but if a
// caller passes viewOnce=true on an unrelated inner we still wrap
// (whatsmeow / WhatsApp may reject; not our enforcement layer).
//
// Nesting order: ViewOnce inside Ephemeral. The outer EphemeralMessage
// is what the server uses for retention; the inner ViewOnceMessageV2
// is what the recipient client uses to gate the reveal flow.
func wrapForChat(inner *waE2E.Message, ephemeralSec int32, viewOnce bool) *waE2E.Message {
	out := inner
	if viewOnce {
		out = &waE2E.Message{
			ViewOnceMessageV2: &waE2E.FutureProofMessage{
				Message: out,
			},
		}
	}
	if ephemeralSec > 0 {
		out = &waE2E.Message{
			EphemeralMessage: &waE2E.FutureProofMessage{
				Message: out,
			},
		}
	}
	return out
}

// PinMessageInChat pins or unpins a target message inside its
// chat. WhatsApp distributes the pin via a normal stanza carrying
// a PinInChatMessage payload — every participant's client (including
// other companion devices on the same account) receives it as a
// regular Message event and renders it as a banner above the
// conversation. `targetSenderJID` is the original message's sender
// (1:1: chat; group: participant). Returns JSON of JSendResult.
func (c *Client) PinMessageInChat(chatJID, targetMsgID, targetSenderJID string, targetFromMe, pin bool) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	var sender types.JID
	if targetFromMe {
		if c.wa.Store != nil && c.wa.Store.ID != nil {
			sender = c.wa.Store.ID.ToNonAD()
		} else {
			sender = chat
		}
	} else {
		sender, err = types.ParseJID(targetSenderJID)
		if err != nil {
			return "", fmt.Errorf("parse sender: %w", err)
		}
	}
	pinType := waE2E.PinInChatMessage_PIN_FOR_ALL
	if !pin {
		pinType = waE2E.PinInChatMessage_UNPIN_FOR_ALL
	}
	msg := &waE2E.Message{
		PinInChatMessage: &waE2E.PinInChatMessage{
			Key:               c.wa.BuildMessageKey(chat, sender, types.MessageID(targetMsgID)),
			Type:              pinType.Enum(),
			SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
		},
	}
	// Phone clients require pin metadata on the outer Message:
	//   - MessageAddOnDurationInSecs / MessageAddOnExpiryType set
	//     the visibility window (24h / 7d / 30d on the mobile UI;
	//     7d is the WhatsApp default).
	//   - MessageSecret is a 32-byte random handle that the server
	//     stores per pin envelope so the phone can validate &
	//     surface the banner; without it SendMessage's ack never
	//     arrives and the call hangs.
	if pin {
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return "", fmt.Errorf("pin secret: %w", err)
		}
		msg.MessageContextInfo = &waE2E.MessageContextInfo{
			MessageAddOnDurationInSecs: proto.Uint32(7 * 24 * 60 * 60),
			MessageAddOnExpiryType:     waE2E.MessageContextInfo_STATIC.Enum(),
			MessageSecret:              secret,
		}
	}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send pin: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// SendReaction posts a reaction to a target message. emoji="" removes our
// reaction. targetSenderJID is the original message's sender (group:
// participant, 1:1: chat). targetFromMe indicates whether the original was
// sent by us.
//
// Returns JSON of JSendResult.
func (c *Client) SendReaction(chatJID, targetMsgID, targetSenderJID string, targetFromMe bool, emoji string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	var sender types.JID
	if targetFromMe {
		if c.wa.Store != nil && c.wa.Store.ID != nil {
			sender = c.wa.Store.ID.ToNonAD()
		} else {
			sender = chat
		}
	} else {
		sender, err = types.ParseJID(targetSenderJID)
		if err != nil {
			return "", fmt.Errorf("parse sender: %w", err)
		}
	}
	msg := c.wa.BuildReaction(chat, sender, targetMsgID, emoji)
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send reaction: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// MarkRead sends a read receipt for the given message ids. `senderJID`
// is the original message sender (the participant in groups; the chat
// peer in 1:1). `msgIDsJSON` is a JSON array of message id strings.
//
// whatsmeow's Client.MarkRead defaults to ReceiptTypeRead when no extra
// type is passed, which is what we want for blue-tick semantics.
func (c *Client) MarkRead(chatJID, senderJID, msgIDsJSON string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	sender, err := types.ParseJID(senderJID)
	if err != nil {
		return fmt.Errorf("parse sender: %w", err)
	}
	var idStrings []string
	if err := json.Unmarshal([]byte(msgIDsJSON), &idStrings); err != nil {
		return fmt.Errorf("parse ids: %w", err)
	}
	if len(idStrings) == 0 {
		return nil
	}
	ids := make([]types.MessageID, 0, len(idStrings))
	for _, s := range idStrings {
		ids = append(ids, types.MessageID(s))
	}
	return c.wa.MarkRead(context.Background(), ids, time.Now(), chat, sender)
}

// SendText sends a plain-text message. When mentionedJIDsJSON decodes to
// a non-empty array, the message is sent as an ExtendedTextMessage with a
// ContextInfo whose MentionedJID array carries the pinged JIDs (matches
// WhatsApp's wire format for @mentions). The JSON-string param shape is
// required because gomobile silently drops methods with []string params.
// Pass "" (or "[]") when there are no mentions. When ephemeralSec > 0,
// wraps in EphemeralMessage so disappearing-message retention applies.
// Returns JSON of JSendResult.
func (c *Client) SendText(chatJID, body string, mentionedJIDsJSON string, ephemeralSec int32) (string, error) {
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
	var mentionedJIDs []string
	if mentionedJIDsJSON != "" {
		if err := json.Unmarshal([]byte(mentionedJIDsJSON), &mentionedJIDs); err != nil {
			return "", fmt.Errorf("parse mentionedJIDs: %w", err)
		}
	}
	var inner *waE2E.Message
	if len(mentionedJIDs) == 0 {
		inner = &waE2E.Message{Conversation: proto.String(body)}
	} else {
		inner = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        proto.String(body),
			ContextInfo: &waE2E.ContextInfo{MentionedJID: mentionedJIDs},
		}}
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{
		MessageID: resp.ID,
		Timestamp: resp.Timestamp.Unix(),
	})
	return string(out), nil
}

// ForwardText re-sends text to another chat tagged as forwarded. Plain
// Conversation carries no ContextInfo, so forwards use ExtendedTextMessage
// to carry the IsForwarded flag.
func (c *Client) ForwardText(chatJID, text string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	msg := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:        proto.String(text),
		ContextInfo: &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)},
	}}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send forward text: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// ForwardMedia re-sends already-uploaded media to another chat by
// reconstructing the media proto from the stored MediaRef — no
// re-download/re-upload. WhatsApp media is content-addressed and
// encrypted by mediaKey, so the same CDN blob is reusable across chats.
// `kind` is taken from the ref. `fileName` applies to documents only.
func (c *Client) ForwardMedia(chatJID, refJSON, caption, fileName string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	var ref MediaRef
	if err := json.Unmarshal([]byte(refJSON), &ref); err != nil {
		return "", fmt.Errorf("parse ref: %w", err)
	}
	fwd := &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)}
	var msg *waE2E.Message
	switch ref.Kind {
	case "image":
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Caption: proto.String(caption), URL: proto.String(ref.URL),
			DirectPath: proto.String(ref.DirectPath), MediaKey: ref.MediaKey,
			Mimetype: proto.String(ref.Mimetype), FileEncSHA256: ref.FileEncSHA256,
			FileSHA256: ref.FileSHA256, FileLength: proto.Uint64(ref.FileLength),
			ContextInfo: fwd,
		}}
	case "video":
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			Caption: proto.String(caption), URL: proto.String(ref.URL),
			DirectPath: proto.String(ref.DirectPath), MediaKey: ref.MediaKey,
			Mimetype: proto.String(ref.Mimetype), FileEncSHA256: ref.FileEncSHA256,
			FileSHA256: ref.FileSHA256, FileLength: proto.Uint64(ref.FileLength),
			ContextInfo: fwd,
		}}
	case "audio":
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			URL: proto.String(ref.URL), DirectPath: proto.String(ref.DirectPath),
			MediaKey: ref.MediaKey, Mimetype: proto.String(ref.Mimetype),
			FileEncSHA256: ref.FileEncSHA256, FileSHA256: ref.FileSHA256,
			FileLength: proto.Uint64(ref.FileLength), ContextInfo: fwd,
		}}
	case "document":
		msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			Caption: proto.String(caption), FileName: proto.String(fileName),
			URL: proto.String(ref.URL), DirectPath: proto.String(ref.DirectPath),
			MediaKey: ref.MediaKey, Mimetype: proto.String(ref.Mimetype),
			FileEncSHA256: ref.FileEncSHA256, FileSHA256: ref.FileSHA256,
			FileLength: proto.Uint64(ref.FileLength), ContextInfo: fwd,
		}}
	case "sticker":
		msg = &waE2E.Message{StickerMessage: &waE2E.StickerMessage{
			URL: proto.String(ref.URL), DirectPath: proto.String(ref.DirectPath),
			MediaKey: ref.MediaKey, Mimetype: proto.String(ref.Mimetype),
			FileEncSHA256: ref.FileEncSHA256, FileSHA256: ref.FileSHA256,
			FileLength: proto.Uint64(ref.FileLength), ContextInfo: fwd,
		}}
	default:
		return "", fmt.Errorf("unsupported kind: %q", ref.Kind)
	}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send forward media: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// dispatchMessage converts whatsmeow Message events to JMessage JSON.
func (c *Client) dispatchMessage(evt *events.Message) {
	// Edits across companion devices arrive as a SecretEncryptedMessage
	// wrapper rather than the auto-unwrapped path. Decrypt explicitly
	// when SecretEncType is MESSAGE_EDIT.
	if sec := evt.Message.GetSecretEncryptedMessage(); sec != nil &&
		sec.GetSecretEncType() == waE2E.SecretEncryptedMessage_MESSAGE_EDIT {
		decrypted, err := c.wa.DecryptSecretEncryptedMessage(context.Background(), evt)
		if err == nil && decrypted != nil {
			targetID := sec.GetTargetMessageKey().GetID()
			newText := extractText(decrypted)
			// Some clients wrap the new payload inside a ProtocolMessage
			// with EditedMessage; cover that too.
			if newText == "" {
				if pm := decrypted.GetProtocolMessage(); pm != nil {
					newText = extractText(pm.GetEditedMessage())
					if targetID == "" {
						targetID = pm.GetKey().GetID()
					}
				}
			}
			b, _ := json.Marshal(JMessageEdited{
				ChatJID:   evt.Info.Chat.String(),
				MessageID: targetID,
				NewText:   newText,
				Timestamp: evt.Info.Timestamp.Unix(),
			})
			c.dispatch("MessageEdited", string(b))
		} else {
			fmt.Fprintf(os.Stderr,
				"[yawac/enc-edit] decrypt fail chat=%s sender=%s err=%v\n",
				evt.Info.Chat.String(), evt.Info.Sender.String(), err)
		}
		return
	}
	// Edits are auto-unwrapped by whatsmeow into evt.Message, which
	// still carries a ProtocolMessage{Type=MESSAGE_EDIT, Key, EditedMessage}.
	// The original message id is in the ProtocolMessage Key, the new
	// payload is in ProtocolMessage.EditedMessage. evt.Info.ID is the
	// edit envelope id (not the original) — don't use it.
	if evt.IsEdit {
		pm := evt.Message.GetProtocolMessage()
		if pm == nil || pm.GetKey() == nil {
			return
		}
		b, _ := json.Marshal(JMessageEdited{
			ChatJID:   evt.Info.Chat.String(),
			MessageID: pm.GetKey().GetID(),
			NewText:   extractText(pm.GetEditedMessage()),
			Timestamp: evt.Info.Timestamp.Unix(),
		})
		c.dispatch("MessageEdited", string(b))
		return
	}
	// In-chat pin (WhatsApp's PinInChatMessage). Top-level Message
	// field, not under ProtocolMessage. Surface as a dedicated event
	// so Swift can update the row's pinnedAt and the banner —
	// otherwise classifyMessage would route it as "system" and the
	// pin would render as a noise bubble.
	if pin := evt.Message.GetPinInChatMessage(); pin != nil {
		key := pin.GetKey()
		if key != nil {
			pinned := pin.GetType() == waE2E.PinInChatMessage_PIN_FOR_ALL
			b, _ := json.Marshal(JMessagePinned{
				ChatJID:         evt.Info.Chat.String(),
				TargetMessageID: key.GetID(),
				SenderJID:       evt.Info.Sender.String(),
				Pinned:          pinned,
				Timestamp:       evt.Info.Timestamp.Unix(),
			})
			c.dispatch("MessagePinned", string(b))
		}
		return
	}
	if r := evt.Message.GetReactionMessage(); r != nil {
		c.dispatchReaction(
			evt.Info.Chat.String(),
			evt.Info.Sender.String(),
			evt.Info.Timestamp.Unix(),
			r,
		)
		return
	}
	// Community-announcement groups wrap reactions in EncReactionMessage
	// rather than the plain ReactionMessage. Decrypt and dispatch through
	// the same path so the UI is uniform. See docs/TODO.md "Reactions:
	// Community-announcement encrypted reactions need explicit
	// DecryptReaction".
	if evt.Message.GetEncReactionMessage() != nil {
		decrypted, err := c.wa.DecryptReaction(context.Background(), evt)
		if err == nil && decrypted != nil {
			c.dispatchReaction(
				evt.Info.Chat.String(),
				evt.Info.Sender.String(),
				evt.Info.Timestamp.Unix(),
				decrypted,
			)
		} else {
			fmt.Fprintf(os.Stderr,
				"[yawac/enc-reaction] decrypt fail chat=%s sender=%s err=%v\n",
				evt.Info.Chat.String(), evt.Info.Sender.String(), err)
		}
		return
	}
	// Edits and revokes arrive as ProtocolMessage wrappers; route them to
	// dedicated Swift events rather than a generic "Message" bubble.
	if pm := evt.Message.GetProtocolMessage(); pm != nil {
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			key := pm.GetKey()
			if key == nil {
				return
			}
			b, _ := json.Marshal(JMessageRevoked{
				ChatJID:   evt.Info.Chat.String(),
				MessageID: key.GetID(),
				RevokedBy: evt.Info.Sender.String(),
				Timestamp: evt.Info.Timestamp.Unix(),
			})
			c.dispatch("MessageRevoked", string(b))
			return
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			key := pm.GetKey()
			if key == nil {
				return
			}
			b, _ := json.Marshal(JMessageEdited{
				ChatJID:   evt.Info.Chat.String(),
				MessageID: key.GetID(),
				NewText:   extractText(pm.GetEditedMessage()),
				Timestamp: evt.Info.Timestamp.Unix(),
			})
			c.dispatch("MessageEdited", string(b))
			return
		}
	}
	// Poll updates (votes) are not displayed as chat entries — they
	// become tally updates on the original poll bubble.
	if evt.Message.GetPollUpdateMessage() != nil {
		c.dispatchPollVote(evt)
		return
	}
	kind, loc, locSeq, contact, isViewOnce := classifyMessage(evt.Message)
	jm := JMessage{
		ID:               evt.Info.ID,
		ChatJID:          evt.Info.Chat.String(),
		SenderJID:        evt.Info.Sender.String(),
		SenderPushName:   evt.Info.PushName,
		FromMe:           evt.Info.IsFromMe,
		Timestamp:        evt.Info.Timestamp.Unix(),
		Kind:             kind,
		Location:         loc,
		LocationSequence: locSeq,
		Contact:          contact,
		IsViewOnce:       isViewOnce,
	}
	// After unwrapping view-once, media + text + quoted may live inside
	// the wrapped Message. Resolve the effective payload once and use it
	// for every per-kind getter below.
	inner := unwrapViewOnce(evt.Message)
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
	if ctx := contextInfoFromMessage(inner); ctx != nil && ctx.GetIsForwarded() {
		jm.IsForwarded = true
	}
	if m := inner.GetImageMessage(); m != nil {
		jm.Media = mediaFromImage(m)
	} else if m := inner.GetVideoMessage(); m != nil {
		jm.Media = mediaFromVideo(m)
	} else if m := inner.GetAudioMessage(); m != nil {
		jm.Media = mediaFromAudio(m)
	} else if m := inner.GetDocumentMessage(); m != nil {
		jm.Media = mediaFromDocument(m)
	} else if m := inner.GetStickerMessage(); m != nil {
		jm.Media = mediaFromSticker(m)
	}
	if p := extractPoll(inner); p != nil {
		jm.Poll = p
	}
	b, _ := json.Marshal(jm)
	c.dispatch("Message", string(b))
}

// unwrapViewOnce returns the inner Message of a ViewOnceMessageV2 /
// V2Extension wrapper, or m itself when no wrapper is present.
// classifyMessage performs the same unwrap internally; this helper is
// for callers that also need to reach into the inner payload (media,
// text, context-info) after asking for the kind.
func unwrapViewOnce(m *waE2E.Message) *waE2E.Message {
	if m == nil {
		return nil
	}
	if vo := m.GetViewOnceMessageV2(); vo != nil && vo.Message != nil {
		return vo.Message
	}
	if voe := m.GetViewOnceMessageV2Extension(); voe != nil && voe.Message != nil {
		return voe.Message
	}
	return m
}

// classifyMessage maps an inbound *waE2E.Message to its kind +
// any structured payload (location, contact) + the view-once flag.
// Unwraps ViewOnceMessageV2 / V2Extension transparently and sets
// isViewOnce=true on the envelope so downstream renderers can mark
// the bubble without a second pass.
func classifyMessage(m *waE2E.Message) (
	kind string,
	loc *JLocationPayload,
	locSeq int64,
	contact *JContactPayload,
	isViewOnce bool,
) {
	if m == nil {
		return "system", nil, 0, nil, false
	}
	// Unwrap view-once first. Both V2 and the V2Extension carry the
	// real payload in their inner Message; classify against that.
	if vo := m.GetViewOnceMessageV2(); vo != nil && vo.Message != nil {
		isViewOnce = true
		m = vo.Message
	} else if voe := m.GetViewOnceMessageV2Extension(); voe != nil && voe.Message != nil {
		isViewOnce = true
		m = voe.Message
	}

	switch {
	case m.GetLocationMessage() != nil:
		lm := m.GetLocationMessage()
		return "location", &JLocationPayload{
			Lat:     lm.GetDegreesLatitude(),
			Lng:     lm.GetDegreesLongitude(),
			Name:    lm.GetName(),
			Address: lm.GetAddress(),
		}, 0, nil, isViewOnce
	case m.GetLiveLocationMessage() != nil:
		ll := m.GetLiveLocationMessage()
		return "location_live", &JLocationPayload{
			Lat: ll.GetDegreesLatitude(),
			Lng: ll.GetDegreesLongitude(),
		}, ll.GetSequenceNumber(), nil, isViewOnce
	case m.GetContactMessage() != nil:
		cm := m.GetContactMessage()
		return "contact", nil, 0, &JContactPayload{
			Vcard:       cm.GetVcard(),
			DisplayName: cm.GetDisplayName(),
		}, isViewOnce
	}
	return classifyKindUnwrapped(m), nil, 0, nil, isViewOnce
}

// classifyKindUnwrapped is the legacy kind-detection switch — it
// assumes the caller has already unwrapped any view-once wrappers
// and that the location / contact arms in classifyMessage didn't
// fire. Kept as a helper so the quoted-message path and historical
// dispatchers can still ask "what kind is this?" without caring
// about the payload accessors.
func classifyKindUnwrapped(m *waE2E.Message) string {
	switch {
	case m.GetConversation() != "":
		return "text"
	case m.GetExtendedTextMessage() != nil:
		return "text"
	case m.GetImageMessage() != nil:
		return "image"
	case m.GetVideoMessage() != nil:
		return "video"
	case m.GetAudioMessage() != nil:
		return "audio"
	case m.GetDocumentMessage() != nil:
		return "document"
	case m.GetStickerMessage() != nil:
		return "sticker"
	case m.GetLocationMessage() != nil:
		return "location"
	case m.GetLiveLocationMessage() != nil:
		return "location_live"
	case m.GetContactMessage() != nil:
		return "contact"
	case m.GetReactionMessage() != nil:
		return "reaction"
	case isPollCreation(m):
		return "poll"
	case m.GetPollUpdateMessage() != nil:
		return "poll_vote"
	case m.GetProtocolMessage() != nil:
		return "protocol"
	default:
		return "system"
	}
}

// extractText returns the plain text body of a message, covering the two
// common cases: Conversation (plain 1:1 text) and ExtendedTextMessage (links,
// quotes). Used by the MESSAGE_EDIT handler to surface the edited body.
func extractText(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	if t := m.GetConversation(); t != "" {
		return t
	}
	if e := m.GetExtendedTextMessage(); e != nil {
		return e.GetText()
	}
	return ""
}

func contextInfoFromMessage(m *waE2E.Message) *waE2E.ContextInfo {
	if m == nil {
		return nil
	}
	if e := m.GetExtendedTextMessage(); e != nil {
		return e.GetContextInfo()
	}
	if im := m.GetImageMessage(); im != nil {
		return im.GetContextInfo()
	}
	if vm := m.GetVideoMessage(); vm != nil {
		return vm.GetContextInfo()
	}
	if am := m.GetAudioMessage(); am != nil {
		return am.GetContextInfo()
	}
	if dm := m.GetDocumentMessage(); dm != nil {
		return dm.GetContextInfo()
	}
	if sm := m.GetStickerMessage(); sm != nil {
		return sm.GetContextInfo()
	}
	return nil
}

func extractSnippet(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	if t := m.GetConversation(); t != "" {
		return truncateRunes(t, 120)
	}
	if e := m.GetExtendedTextMessage(); e != nil {
		return truncateRunes(e.GetText(), 120)
	}
	if im := m.GetImageMessage(); im != nil {
		if cap := im.GetCaption(); cap != "" {
			return truncateRunes(cap, 120)
		}
		return "[image]"
	}
	if vm := m.GetVideoMessage(); vm != nil {
		if cap := vm.GetCaption(); cap != "" {
			return truncateRunes(cap, 120)
		}
		return "[video]"
	}
	if am := m.GetAudioMessage(); am != nil {
		_ = am
		return "[audio]"
	}
	if dm := m.GetDocumentMessage(); dm != nil {
		if n := dm.GetFileName(); n != "" {
			return truncateRunes(n, 120)
		}
		return "[document]"
	}
	if sm := m.GetStickerMessage(); sm != nil {
		_ = sm
		return "[sticker]"
	}
	return ""
}

func truncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "…"
}

func isFromMe(c *Client, jid string) bool {
	if c == nil || c.wa == nil || c.wa.Store == nil || c.wa.Store.ID == nil {
		return false
	}
	return c.wa.Store.ID.ToNonAD().String() == jid
}

func mediaFromImage(m *waE2E.ImageMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Caption:   m.GetCaption(),
		Width:     int(m.GetWidth()),
		Height:    int(m.GetHeight()),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "image",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

func mediaFromVideo(m *waE2E.VideoMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Caption:   m.GetCaption(),
		Width:     int(m.GetWidth()),
		Height:    int(m.GetHeight()),
		Duration:  int(m.GetSeconds()),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "video",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

func mediaFromAudio(m *waE2E.AudioMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Duration:  int(m.GetSeconds()),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "audio",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

func mediaFromDocument(m *waE2E.DocumentMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		Caption:   m.GetCaption(),
		FileName:  m.GetFileName(),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "document",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

// dispatchReaction emits a "Reaction" event for both live messages
// (whatsmeow events.Message with ReactionMessage) and history-sync
// WebMessageInfo records. Reactions are NOT delivered as "Message"
// events — Swift treats them as bubble adornments, not chat entries.
func (c *Client) dispatchReaction(chatJID, senderJID string, ts int64, r *waE2E.ReactionMessage) {
	key := r.GetKey()
	if key == nil {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/reaction] dispatch chat=%s sender=%s target=%s emoji=%q\n",
		chatJID, senderJID, key.GetID(), r.GetText())
	payload := JReaction{
		ChatJID:         chatJID,
		TargetMessageID: key.GetID(),
		TargetFromMe:    key.GetFromMe(),
		SenderJID:       senderJID,
		Emoji:           r.GetText(),
		Timestamp:       ts,
	}
	b, _ := json.Marshal(payload)
	c.dispatch("Reaction", string(b))
}

func mediaFromSticker(m *waE2E.StickerMessage) *JMedia {
	return &JMedia{
		MimeType:  m.GetMimetype(),
		SizeBytes: int64(m.GetFileLength()),
		Ref: &MediaRef{
			Kind:          "sticker",
			URL:           m.GetURL(),
			DirectPath:    m.GetDirectPath(),
			MediaKey:      m.GetMediaKey(),
			FileEncSHA256: m.GetFileEncSHA256(),
			FileSHA256:    m.GetFileSHA256(),
			FileLength:    m.GetFileLength(),
			Mimetype:      m.GetMimetype(),
		},
	}
}

// SendTextReply sends a text message that quotes another message.
// quotedKind is one of text/image/video/audio/document/sticker.
// quotedSnippet is what other clients will render if they cannot
// resolve the stanza-id back to the original.
func (c *Client) SendTextReply(
	chatJID, body, quotedID, quotedSenderJID string,
	quotedFromMe bool, quotedKind, quotedSnippet string,
	mentionedJIDsJSON string,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return "", fmt.Errorf("parse chat: %q is not a valid jid", chatJID)
	}
	senderForCtx := quotedSenderJID
	if quotedFromMe {
		if c.wa.Store != nil && c.wa.Store.ID != nil {
			senderForCtx = c.wa.Store.ID.ToNonAD().String()
		}
	} else {
		if _, err := types.ParseJID(quotedSenderJID); err != nil {
			return "", fmt.Errorf("parse quoted sender: %w", err)
		}
	}
	var mentionedJIDs []string
	if mentionedJIDsJSON != "" {
		if err := json.Unmarshal([]byte(mentionedJIDsJSON), &mentionedJIDs); err != nil {
			return "", fmt.Errorf("parse mentionedJIDs: %w", err)
		}
	}
	ctx := &waE2E.ContextInfo{
		StanzaID:      proto.String(quotedID),
		Participant:   proto.String(senderForCtx),
		QuotedMessage: stubQuoted(quotedKind, quotedSnippet),
		MentionedJID:  mentionedJIDs,
	}
	msg := &waE2E.Message{
		ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        proto.String(body),
			ContextInfo: ctx,
		},
	}
	resp, err := c.wa.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// SendLocation sends a static LocationMessage. lat/lng in decimal
// degrees. name + address may be empty. When ephemeralSec > 0,
// wraps in EphemeralMessage. Returns JSON of JSendResult.
func (c *Client) SendLocation(
	chatJIDStr string,
	lat, lng float64,
	name, address string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return "", fmt.Errorf("parse jid: %q is not a valid jid", chatJIDStr)
	}
	inner := &waE2E.Message{
		LocationMessage: &waE2E.LocationMessage{
			DegreesLatitude:  proto.Float64(lat),
			DegreesLongitude: proto.Float64(lng),
			Name:             proto.String(name),
			Address:          proto.String(address),
		},
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// SendContact sends a single-contact ContactMessage. vcard must be
// a valid VCARD 3.0 payload (built Swift-side via VCardBuilder).
// displayName is the human-readable name. When ephemeralSec > 0,
// wraps in EphemeralMessage.
func (c *Client) SendContact(
	chatJIDStr string,
	vcard, displayName string,
	ephemeralSec int32,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJIDStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	// Empty-jid guard matches SendText / SendLocation pattern
	// so bad inputs surface as parse errors not send errors.
	if jid.User == "" || jid.Server == "" {
		return "", fmt.Errorf("parse jid: empty user or server")
	}
	inner := &waE2E.Message{
		ContactMessage: &waE2E.ContactMessage{
			DisplayName: proto.String(displayName),
			Vcard:       proto.String(vcard),
		},
	}
	msg := wrapForChat(inner, ephemeralSec, false)
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send: %w", err)
	}
	out := JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()}
	b, _ := json.Marshal(out)
	return string(b), nil
}

func stubQuoted(kind, snippet string) *waE2E.Message {
	switch kind {
	case "image":
		return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String(snippet)}}
	case "video":
		return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{Caption: proto.String(snippet)}}
	case "audio":
		return &waE2E.Message{AudioMessage: &waE2E.AudioMessage{}}
	case "document":
		return &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: proto.String(snippet)}}
	case "sticker":
		return &waE2E.Message{StickerMessage: &waE2E.StickerMessage{}}
	default: // "text" and unknown kinds
		return &waE2E.Message{Conversation: proto.String(snippet)}
	}
}
