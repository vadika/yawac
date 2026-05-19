package bridge

import (
	"context"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
)

func (c *Client) SendPresence(available bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if available {
		return c.wa.SendPresence(context.Background(), types.PresenceAvailable)
	}
	return c.wa.SendPresence(context.Background(), types.PresenceUnavailable)
}

func (c *Client) SendTyping(chatJID string, typing bool) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" || jid.Server == "" {
		return fmt.Errorf("parse jid: %q is not a valid jid", chatJID)
	}
	state := types.ChatPresencePaused
	if typing {
		state = types.ChatPresenceComposing
	}
	return c.wa.SendChatPresence(context.Background(), jid, state, types.ChatPresenceMediaText)
}

func (c *Client) SubscribePresence(jid string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	j, err := types.ParseJID(jid)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	if j.User == "" || j.Server == "" {
		return fmt.Errorf("parse jid: %q is not a valid jid", jid)
	}
	return c.wa.SubscribePresence(context.Background(), j)
}
