package bridge

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"go.mau.fi/whatsmeow/appstate"
)

// SetSelfAvatar sets the paired account's profile picture by
// invoking SetGroupPhoto with the user's own JID. WhatsApp uses
// the same RPC for groups and self.
func (c *Client) SetSelfAvatar(jpegBytes []byte) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	own := c.wa.Store.ID
	if own == nil {
		return errors.New("not paired")
	}
	_, err := c.wa.SetGroupPhoto(context.Background(), own.ToNonAD(), jpegBytes)
	if err != nil {
		return fmt.Errorf("set self avatar: %w", err)
	}
	return nil
}

// RemoveSelfAvatar clears the paired account's profile picture.
func (c *Client) RemoveSelfAvatar() error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	own := c.wa.Store.ID
	if own == nil {
		return errors.New("not paired")
	}
	_, err := c.wa.SetGroupPhoto(context.Background(), own.ToNonAD(), nil)
	if err != nil {
		return fmt.Errorf("remove self avatar: %w", err)
	}
	return nil
}

// SetSelfAbout updates the paired account's About / status message.
func (c *Client) SetSelfAbout(msg string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if err := c.wa.SetStatusMessage(context.Background(), msg); err != nil {
		return fmt.Errorf("set status message: %w", err)
	}
	return nil
}

// OwnPushName returns the paired account's own push name as known to
// whatsmeow's local store (synced from the phone via app-state). Empty
// string when not paired or before app-state has settled.
func (c *Client) OwnPushName() string {
	if c.wa == nil || c.wa.Store == nil {
		return ""
	}
	return c.wa.Store.PushName
}

// SetSelfPushName updates the paired account's push name (display
// name shown to peers) via a SETTING_PUSHNAME app-state patch.
// Whatsmeow's appstate.BuildSettingPushName does the heavy lifting;
// SendAppState ships the patch and triggers a background resync.
func (c *Client) SetSelfPushName(name string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if c.wa.Store == nil || c.wa.Store.ID == nil {
		return errors.New("not logged in")
	}
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return errors.New("push name cannot be empty")
	}
	return c.wa.SendAppState(context.Background(),
		appstate.BuildSettingPushName(trimmed))
}
