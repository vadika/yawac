package bridge

import (
	"context"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow"
)

// Connect opens a websocket to WhatsApp. If unpaired, QR events will be
// emitted via the EventSink ("QR" kind) until the user scans or times out.
func (c *Client) Connect() error {
	c.mu.Lock()
	if c.wa == nil {
		c.mu.Unlock()
		return errors.New("client closed")
	}
	c.wa.AddEventHandler(c.handleWAEvent)
	// Install (or replace) the lifecycle context that background loops
	// use to know when the client is closing. Cancel any prior one so we
	// don't leak ticker goroutines across Connect → Close → Connect
	// cycles within the same process.
	if c.cancel != nil {
		c.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	c.mu.Unlock()

	if c.wa.Store.ID == nil {
		qrChan, err := c.wa.GetQRChannel(context.Background())
		if err != nil && !errors.Is(err, whatsmeow.ErrQRStoreContainsID) {
			return fmt.Errorf("qr channel: %w", err)
		}
		go c.pumpQR(qrChan)
	}
	if err := c.wa.Connect(); err != nil {
		return err
	}
	// Background prekey top-up: whatsmeow only checks the server count
	// at Connect-time, so long-running sessions can fall below
	// MinPreKeyCount. We poll every 30 minutes and upload more if so.
	c.startPrekeyTopUpLoop(ctx)
	return nil
}

func (c *Client) pumpQR(ch <-chan whatsmeow.QRChannelItem) {
	for evt := range ch {
		switch evt.Event {
		case "code":
			c.dispatch("QR", fmt.Sprintf(`{"code":%q}`, evt.Code))
		case "success":
			c.dispatch("PairSuccess", `{}`)
		case "timeout":
			c.dispatch("PairTimeout", `{}`)
		case "err-client-outdated":
			c.dispatch("PairError", `{"reason":"client-outdated"}`)
		default:
			c.dispatch("PairEvent", fmt.Sprintf(`{"event":%q}`, evt.Event))
		}
	}
}

// Logout deletes credentials and disconnects.
func (c *Client) Logout() error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	return c.wa.Logout(context.Background())
}
