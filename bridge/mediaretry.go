package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"go.mau.fi/whatsmeow"
	waMmsRetry "go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// RequestMediaRetry asks the phone to re-upload the media identified by msgID.
// refJSON is the MediaRef we already have on file — we stash a copy keyed by
// msgID so we can resume the download once *events.MediaRetry arrives.
// fromMe indicates whether the message was originally sent by us; whatsmeow
// uses it when building the retry receipt.
func (c *Client) RequestMediaRetry(chatJID, senderJID, msgID string, fromMe bool, refJSON string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	var ref MediaRef
	if err := json.Unmarshal([]byte(refJSON), &ref); err != nil {
		return fmt.Errorf("parse ref: %w", err)
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse chat jid: %w", err)
	}
	sender, err := types.ParseJID(senderJID)
	if err != nil {
		return fmt.Errorf("parse sender jid: %w", err)
	}

	isGroup := chat.Server == types.GroupServer
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chat,
			Sender:   sender,
			IsFromMe: fromMe,
			IsGroup:  isGroup,
		},
		ID: msgID,
	}

	c.retryMu.Lock()
	if c.pendingRetry == nil {
		c.pendingRetry = map[string]MediaRef{}
	}
	c.pendingRetry[msgID] = ref
	c.retryMu.Unlock()

	if err := c.wa.SendMediaRetryReceipt(context.Background(), info, ref.MediaKey); err != nil {
		c.retryMu.Lock()
		delete(c.pendingRetry, msgID)
		c.retryMu.Unlock()
		return fmt.Errorf("send retry receipt: %w", err)
	}
	return nil
}

// handleMediaRetry decrypts an incoming MediaRetry event using the stashed
// MediaKey, then dispatches a "MediaRetry" event to Swift with either the
// fresh DirectPath (on success) or an error string.
func (c *Client) handleMediaRetry(evt *events.MediaRetry) {
	msgID := evt.MessageID
	c.retryMu.Lock()
	ref, ok := c.pendingRetry[msgID]
	c.retryMu.Unlock()
	if !ok {
		// Not one of ours — could be a retry triggered by another device.
		return
	}

	hasError := evt.Error != nil
	hasCipher := evt.Ciphertext != nil
	errCode := 0
	if evt.Error != nil {
		errCode = evt.Error.Code
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/media-retry] evt msgID=%s mediaKey=%dB cipher=%dB iv=%dB error=%v code=%d\n",
		msgID, len(ref.MediaKey), len(evt.Ciphertext), len(evt.IV), hasError, errCode)
	_ = hasCipher

	retryData, err := whatsmeow.DecryptMediaRetryNotification(evt, ref.MediaKey)
	if err != nil {
		payload := map[string]any{
			"message_id": msgID,
			"ok":         false,
			"error":      fmt.Sprintf("decrypt: %v", err),
		}
		b, _ := json.Marshal(payload)
		c.dispatch("MediaRetry", string(b))
		return
	}
	if retryData.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS {
		payload := map[string]any{
			"message_id": msgID,
			"ok":         false,
			"error":      fmt.Sprintf("retry result: %v", retryData.GetResult()),
		}
		b, _ := json.Marshal(payload)
		c.dispatch("MediaRetry", string(b))
		return
	}

	// Update stashed ref with new DirectPath; leave it installed so a
	// second retry call (e.g. if Swift's first download still 4xx's after
	// the refresh) can reuse the latest known-good path.
	ref.DirectPath = retryData.GetDirectPath()
	c.retryMu.Lock()
	c.pendingRetry[msgID] = ref
	c.retryMu.Unlock()

	payload := map[string]any{
		"message_id":  msgID,
		"ok":          true,
		"direct_path": retryData.GetDirectPath(),
	}
	b, _ := json.Marshal(payload)
	c.dispatch("MediaRetry", string(b))
}
