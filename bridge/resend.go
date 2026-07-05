package bridge

import (
	"context"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
)

// RequestMessageResend asks the primary phone to resend a message this
// client never received or failed to decrypt (PLACEHOLDER_MESSAGE_RESEND
// peer request — what WhatsApp Web uses for "Waiting for this message").
// The resent copy arrives as a normal Message event through the usual
// pipeline. The phone must be online and still hold the message. F118.
func (c *Client) RequestMessageResend(chatJID, senderJID, msgID string) error {
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("chat jid: %w", err)
	}
	sender, err := types.ParseJID(senderJID)
	if err != nil {
		return fmt.Errorf("sender jid: %w", err)
	}
	if c.wa == nil {
		return errors.New("client closed")
	}
	req := c.wa.BuildUnavailableMessageRequest(chat, sender, msgID)
	if _, err := c.wa.SendPeerMessage(context.Background(), req); err != nil {
		return fmt.Errorf("send placeholder-resend request: %w", err)
	}
	return nil
}
