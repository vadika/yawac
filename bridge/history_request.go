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

// RequestFullHistorySync builds an on-demand history-sync request
// anchored on a known (chatJID, msgID, fromMe, ts) tuple and sends
// it via SendPeerMessage. The server replies with one or more
// events.HistorySync; existing applyHistorySync persists their
// messages through the v0.8.0 classifier (isViewOnce +
// ContextInfo.Expiration hint).
//
// Unlike RequestOlderHistory (per-chat, finer-grained), this is the
// session-level full-backfill wrapper: SessionViewModel fires it once
// post-pair so the app reseeds disappearing/view-once history that
// vanished from the linked-device cache.
//
// count is the requested message count; whatsmeow and the server
// cap below the requested value in practice.
func (c *Client) RequestFullHistorySync(
	beforeChatJID, beforeMsgID string, beforeFromMe bool,
	beforeTSUnix int64,
	count int32,
) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	chat, err := types.ParseJID(beforeChatJID)
	if err != nil {
		return fmt.Errorf("parse chat: %w", err)
	}
	if chat.User == "" || chat.Server == "" {
		return fmt.Errorf("parse chat: empty user or server")
	}
	if c.wa.Store == nil || c.wa.Store.ID == nil {
		return errors.New("not logged in")
	}
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chat,
			IsFromMe: beforeFromMe,
		},
		ID:        beforeMsgID,
		Timestamp: time.Unix(beforeTSUnix, 0),
	}
	req := c.wa.BuildHistorySyncRequest(info, int(count))
	if req == nil {
		return errors.New("nil history-sync request")
	}
	if _, err := c.wa.SendPeerMessage(context.Background(), req); err != nil {
		return fmt.Errorf("send history-sync request: %w", err)
	}
	return nil
}
