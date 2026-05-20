package bridge

import (
	"context"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// RequestOlderHistory asks the phone to send up to `count` messages older
// than the supplied anchor. The response arrives asynchronously as an
// *events.HistorySync of SyncType ON_DEMAND, handled by applyHistorySync —
// no special routing needed Swift-side beyond watching for new Message
// events for previously-unseen IDs.
func (c *Client) RequestOlderHistory(
	chatJID, oldestMsgID, oldestSenderJID string,
	oldestFromMe bool, oldestTimestampSec int64, count int,
) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	var sender types.JID
	if oldestFromMe {
		if c.wa.Store != nil && c.wa.Store.ID != nil {
			sender = c.wa.Store.ID.ToNonAD()
		} else {
			sender = chat
		}
	} else {
		sender, err = types.ParseJID(oldestSenderJID)
		if err != nil {
			return fmt.Errorf("parse sender: %w", err)
		}
	}
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chat,
			Sender:   sender,
			IsFromMe: oldestFromMe,
			IsGroup:  chat.Server == types.GroupServer,
		},
		ID:        oldestMsgID,
		Timestamp: time.Unix(oldestTimestampSec, 0),
	}
	if count <= 0 {
		count = 50
	}
	msg := c.wa.BuildHistorySyncRequest(info, count)
	_, err = c.wa.SendPeerMessage(context.Background(), msg)
	if err != nil {
		return fmt.Errorf("send peer: %w", err)
	}
	return nil
}
