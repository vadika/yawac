package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// StarMessage stars or unstars a target message via the WhatsApp
// appstate sync channel (WAPatchRegularHigh). The action propagates
// to the user's other devices; locally we update the row eagerly
// without waiting for the round-trip echo.
//
// `targetSenderJID` is the original message's sender (group:
// participant; 1:1: chat). `targetFromMe` mirrors the sender check
// used by reactions.
func (c *Client) StarMessage(chatJID, targetMsgID, targetSenderJID string, targetFromMe, starred bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
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
			return fmt.Errorf("parse sender: %w", err)
		}
	}
	patch := appstate.BuildStar(chat, sender, types.MessageID(targetMsgID), targetFromMe, starred)
	return c.wa.SendAppState(context.Background(), patch)
}

// ListPinnedChats walks the input JID list and returns those that
// whatsmeow's local appstate store currently considers pinned.
// Used by Swift on cold-start to reconcile sidebar state with the
// server snapshot, since whatsmeow doesn't re-emit events.Pin for
// already-synced patches on reconnect.
//
// `jidsJSON` is a JSON array of chat JID strings; the return value
// is a JSON array of the subset that is pinned.
func (c *Client) ListPinnedChats(jidsJSON string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if c.wa.Store == nil || c.wa.Store.ChatSettings == nil {
		return "[]", nil
	}
	var jids []string
	if err := json.Unmarshal([]byte(jidsJSON), &jids); err != nil {
		return "", fmt.Errorf("parse jids: %w", err)
	}
	out := make([]string, 0, 8)
	for _, raw := range jids {
		jid, err := types.ParseJID(raw)
		if err != nil {
			continue
		}
		settings, err := c.wa.Store.ChatSettings.GetChatSettings(context.Background(), jid)
		if err != nil || !settings.Found {
			continue
		}
		if settings.Pinned {
			out = append(out, raw)
		}
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// PinChat pins or unpins a chat in the sidebar. The mutation is
// synced via WhatsApp app-state (WAPatchRegularLow) and propagates
// to the user's other devices.
func (c *Client) PinChat(chatJID string, pinned bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	patch := appstate.BuildPin(chat, pinned)
	return c.wa.SendAppState(context.Background(), patch)
}

// MuteChat mutes or unmutes a chat. mutedUntilUnixMs is the absolute
// Unix-millisecond timestamp when the mute expires; pass the
// year-9999 UTC sentinel for "Always", 0 for unmute. The patch
// propagates via WhatsApp app-state to peer devices.
func (c *Client) MuteChat(chatJID string, mute bool, mutedUntilUnixMs int64) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	var ts *int64
	if mute && mutedUntilUnixMs != 0 {
		ts = &mutedUntilUnixMs
	}
	patch := appstate.BuildMuteAbs(chat, mute, ts)
	return c.wa.SendAppState(context.Background(), patch)
}

// ListMutedChats walks the input JID list and returns the subset that
// whatsmeow's local appstate store currently considers muted, with
// each entry's MutedUntil expressed as Unix milliseconds. Used by
// Swift on cold-start to reconcile sidebar state with the server
// snapshot, since whatsmeow doesn't re-emit events.Mute for
// already-synced patches on reconnect.
//
// `jidsJSON` is a JSON array of chat JID strings; the return value is
// a JSON array of {chat_jid, muted_until_ms} entries.
func (c *Client) ListMutedChats(jidsJSON string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if c.wa.Store == nil || c.wa.Store.ChatSettings == nil {
		return "[]", nil
	}
	var jids []string
	if err := json.Unmarshal([]byte(jidsJSON), &jids); err != nil {
		return "", fmt.Errorf("parse jids: %w", err)
	}
	type entry struct {
		ChatJID      string `json:"chat_jid"`
		MutedUntilMs int64  `json:"muted_until_ms"`
	}
	out := make([]entry, 0, 8)
	now := time.Now()
	for _, raw := range jids {
		jid, err := types.ParseJID(raw)
		if err != nil {
			continue
		}
		settings, err := c.wa.Store.ChatSettings.GetChatSettings(context.Background(), jid)
		if err != nil || !settings.Found {
			continue
		}
		mu := settings.MutedUntil
		if mu.IsZero() || !mu.After(now) {
			continue
		}
		out = append(out, entry{
			ChatJID:      raw,
			MutedUntilMs: mu.UnixMilli(),
		})
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// messageKeyOrNil builds a *waCommon.MessageKey for archive/delete message
// ranges, or nil when no last-message id is known. whatsmeow's
// newMessageRange is zero-safe and substitutes time.Now() for a zero
// timestamp, so passing nil here is valid for empty chats.
func messageKeyOrNil(chat types.JID, lastMsgID string, fromMe bool) *waCommon.MessageKey {
	if lastMsgID == "" {
		return nil
	}
	return &waCommon.MessageKey{
		RemoteJID: proto.String(chat.String()),
		FromMe:    proto.Bool(fromMe),
		ID:        proto.String(lastMsgID),
	}
}

// ArchiveChat archives or unarchives a chat. whatsmeow's BuildArchive uses
// WAPatchRegularLow (version 3) and auto-unpins the chat when archiving.
// lastTS/lastMsgID/fromMe anchor the archive to the chat's last message;
// pass 0/""/false when unknown.
func (c *Client) ArchiveChat(chatJID string, archived bool, lastTS int64, lastMsgID string, fromMe bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	ts := time.Time{}
	if lastTS > 0 {
		ts = time.Unix(lastTS, 0)
	}
	patch := appstate.BuildArchive(chat, archived, ts, messageKeyOrNil(chat, lastMsgID, fromMe))
	return c.wa.SendAppState(context.Background(), patch)
}

// buildContactPatch constructs the appstate patch that saves a contact name,
// synced to the phone address book. whatsmeow ships no helper for the
// "contact" index, so we assemble it directly (modeled on appstate.BuildPin).
// Version 2 is the WhatsApp contact-action version; if the server rejects the
// patch in live testing, this is the value to revisit (see spec).
func buildContactPatch(target types.JID, fullName, firstName string) appstate.PatchInfo {
	action := &waSyncAction.ContactAction{
		FullName:                 proto.String(fullName),
		SaveOnPrimaryAddressbook: proto.Bool(true),
	}
	if firstName != "" {
		action.FirstName = proto.String(firstName)
	}
	return appstate.PatchInfo{
		Type: appstate.WAPatchCriticalUnblockLow,
		Mutations: []appstate.MutationInfo{{
			Index:   []string{appstate.IndexContact, target.String()},
			Version: 2,
			Value:   &waSyncAction.SyncActionValue{ContactAction: action},
		}},
	}
}

// SetContactName saves a display name for jid, synced to the phone address
// book and the user's other linked devices.
func (c *Client) SetContactName(jid, fullName, firstName string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	target, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.SendAppState(context.Background(), buildContactPatch(target, fullName, firstName))
}

// DeleteChat clears a conversation on every device. whatsmeow's
// BuildDeleteChat uses WAPatchRegularHigh (version 6); we never delete media
// server-side (deleteMedia=false).
func (c *Client) DeleteChat(chatJID string, lastTS int64, lastMsgID string, fromMe bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	ts := time.Time{}
	if lastTS > 0 {
		ts = time.Unix(lastTS, 0)
	}
	patch := appstate.BuildDeleteChat(chat, ts, messageKeyOrNil(chat, lastMsgID, fromMe), false)
	return c.wa.SendAppState(context.Background(), patch)
}
