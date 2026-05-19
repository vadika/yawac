package bridge

import (
	"encoding/json"

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
	}
}

// stubs — filled in later tasks
func (c *Client) dispatchMessage(*events.Message)           {}
func (c *Client) dispatchReceipt(*events.Receipt)           {}
func (c *Client) dispatchPresence(*events.Presence)         {}
func (c *Client) dispatchChatPresence(*events.ChatPresence) {}
func (c *Client) dispatchHistory(*events.HistorySync)       {}
