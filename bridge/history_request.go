package bridge

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
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

// RequestFullHistorySync issues a FULL_HISTORY_SYNC_ON_DEMAND
// PeerDataOperationRequestMessage (type 6) — the account-wide
// deep-history variant — and sends it via SendPeerMessage.
//
// Whatsmeow's BuildHistorySyncRequest only builds the per-chat
// HISTORY_SYNC_ON_DEMAND variant (type 5), which the phone caps to
// ~50 messages. The type-6 FULL variant asks the phone for up to
// `count` days of full account history. Confirmed via the F-instr
// trace 2026-06-09 that the phone has years of history but never
// shipped it because yawac never built the type-6 request.
//
// The Swift signature still takes (beforeChatJID, beforeMsgID,
// beforeFromMe, beforeTSUnix, count) so the existing call site
// compiles unchanged. For the FULL variant only `count` is used
// (mapped to HistoryDurationDays). The other anchor fields are
// kept for backward source compatibility and possible per-chat
// retry use.
//
// Phone-side response is one or more events.HistorySync chunks of
// SyncType ON_DEMAND; applyHistorySync persists their messages
// through the existing classifier.
func (c *Client) RequestFullHistorySync(
	beforeChatJID, beforeMsgID string, beforeFromMe bool,
	beforeTSUnix int64,
	count int32,
) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if c.wa.Store == nil || c.wa.Store.ID == nil {
		return errors.New("not logged in")
	}
	// count maps to "how many days of history" for the FULL variant.
	// Bracketed to a sane range so a bad caller can't ask for 100k days.
	days := uint32(count)
	if days == 0 {
		days = 3650 // ~10 years default
	}
	if days > 3650 {
		days = 3650
	}
	requestID := newRequestID()
	req := &waE2E.Message{
		ProtocolMessage: &waE2E.ProtocolMessage{
			Type: waE2E.ProtocolMessage_PEER_DATA_OPERATION_REQUEST_MESSAGE.Enum(),
			PeerDataOperationRequestMessage: &waE2E.PeerDataOperationRequestMessage{
				PeerDataOperationRequestType: waE2E.PeerDataOperationRequestType_FULL_HISTORY_SYNC_ON_DEMAND.Enum(),
				FullHistorySyncOnDemandRequest: &waE2E.PeerDataOperationRequestMessage_FullHistorySyncOnDemandRequest{
					RequestMetadata: &waE2E.FullHistorySyncOnDemandRequestMetadata{
						RequestID: proto.String(requestID),
					},
					FullHistorySyncOnDemandConfig: &waE2E.FullHistorySyncOnDemandConfig{
						HistoryFromTimestamp: proto.Uint64(uint64(time.Now().Unix())),
						HistoryDurationDays:  proto.Uint32(days),
					},
				},
			},
		},
	}
	if _, err := c.wa.SendPeerMessage(context.Background(), req); err != nil {
		return fmt.Errorf("send full-history-sync-on-demand: %w", err)
	}
	return nil
}

// newRequestID returns a hex-encoded 16-byte ID for the
// FullHistorySyncOnDemandRequestMetadata. Phone correlates response
// chunks back to the originating request via this ID.
func newRequestID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
