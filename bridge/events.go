package bridge

import (
	"encoding/json"
	"fmt"
	"os"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// SetEventSink installs the Swift-side callback target.
// Replaces any prior sink.
func (c *Client) SetEventSink(s EventSink) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sink = s
}

// dispatch is the single point where Go events fan out to the Swift sink.
// Always async to keep the whatsmeow event goroutine non-blocking.
func (c *Client) dispatch(kind, payload string) {
	c.mu.Lock()
	sink := c.sink
	c.mu.Unlock()
	if sink == nil {
		return
	}
	go sink.OnEvent(kind, payload)
}

// handleWAEvent is registered with whatsmeow.Client.AddEventHandler.
func (c *Client) handleWAEvent(evt any) {
	switch v := evt.(type) {
	case *events.Connected:
		c.dispatch("Connected", "{}")
	case *events.Disconnected:
		c.dispatch("Disconnected", "{}")
	case *events.LoggedOut:
		b, _ := json.Marshal(map[string]any{"reason": v.Reason.String()})
		c.dispatch("LoggedOut", string(b))
	case *events.QR:
		b, _ := json.Marshal(map[string]any{"codes": v.Codes})
		c.dispatch("QR", string(b))
	case *events.PairSuccess:
		b, _ := json.Marshal(map[string]any{
			"id":       v.ID.String(),
			"platform": v.Platform,
		})
		c.dispatch("PairSuccess", string(b))
	case *events.Message:
		c.dispatchMessage(v)
	case *events.Receipt:
		c.dispatchReceipt(v)
	case *events.Presence:
		c.dispatchPresence(v)
	case *events.ChatPresence:
		c.dispatchChatPresence(v)
	case *events.HistorySync:
		c.dispatchHistory(v)
	case *events.MediaRetry:
		c.handleMediaRetry(v)
	case *events.DeleteForMe:
		c.dispatchDeleteForMe(v)
	case *events.Star:
		c.dispatchStar(v)
	case *events.Pin:
		c.dispatchPin(v)
	}
}

// dispatchPin surfaces app-state pin/unpin events (a chat pinned
// or unpinned from another companion device).
func (c *Client) dispatchPin(evt *events.Pin) {
	pinned := false
	if a := evt.Action; a != nil {
		pinned = a.GetPinned()
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/pin] dispatch jid=%s pinned=%v fullSync=%v\n",
		evt.JID.String(), pinned, evt.FromFullSync)
	b, _ := json.Marshal(JChatPinned{
		ChatJID:   evt.JID.String(),
		Pinned:    pinned,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("ChatPinned", string(b))
}

// dispatchStar surfaces app-state star/unstar events (a message
// (un)starred from another companion device) so the local row's
// starredAt can be reconciled without a round-trip.
func (c *Client) dispatchStar(evt *events.Star) {
	starred := false
	if a := evt.Action; a != nil {
		starred = a.GetStarred()
	}
	b, _ := json.Marshal(JMessageStarred{
		ChatJID:   evt.ChatJID.String(),
		MessageID: evt.MessageID,
		SenderJID: evt.SenderJID.String(),
		FromMe:    evt.IsFromMe,
		Starred:   starred,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("MessageStarred", string(b))
}

// dispatchDeleteForMe surfaces app-state "delete-for-me" events
// (a message hidden on another companion device, not revoked
// globally) to the Swift side as MessageLocallyDeleted.
func (c *Client) dispatchDeleteForMe(evt *events.DeleteForMe) {
	b, _ := json.Marshal(JMessageLocallyDeleted{
		ChatJID:   evt.ChatJID.String(),
		MessageID: evt.MessageID,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("MessageLocallyDeleted", string(b))
}

func (c *Client) dispatchReceipt(evt *events.Receipt) {
	status := "delivered"
	switch evt.Type {
	case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
		status = "read"
	case types.ReceiptTypePlayed:
		status = "played"
	case types.ReceiptTypeDelivered:
		status = "delivered"
	}
	b, _ := json.Marshal(JReceipt{
		ChatJID:    evt.Chat.String(),
		SenderJID:  evt.Sender.String(),
		MessageIDs: evt.MessageIDs,
		Status:     status,
		Timestamp:  evt.Timestamp.Unix(),
	})
	c.dispatch("Receipt", string(b))
}

func (c *Client) dispatchPresence(evt *events.Presence) {
	b, _ := json.Marshal(map[string]any{
		"from":        evt.From.String(),
		"unavailable": evt.Unavailable,
		"last_seen":   evt.LastSeen.Unix(),
	})
	c.dispatch("Presence", string(b))
}

func (c *Client) dispatchChatPresence(evt *events.ChatPresence) {
	b, _ := json.Marshal(map[string]any{
		"chat":   evt.MessageSource.Chat.String(),
		"sender": evt.MessageSource.Sender.String(),
		"state":  string(evt.State), // composing, paused
		"media":  string(evt.Media), // text, audio
	})
	c.dispatch("ChatPresence", string(b))
}

func (c *Client) dispatchHistory(evt *events.HistorySync) {
	c.applyHistorySync(evt)
	convs := evt.Data.GetConversations()
	payload := map[string]any{
		"sync_type":     evt.Data.GetSyncType().String(),
		"conversations": len(convs),
	}
	b, _ := json.Marshal(payload)
	c.dispatch("HistorySync", string(b))
}
