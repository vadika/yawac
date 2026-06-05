package bridge

import (
	"context"
	"errors"
	"fmt"
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
