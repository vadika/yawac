package bridge

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.mau.fi/whatsmeow"
)

// prekeyTopUpInterval is how often we poll the server for our prekey
// count. whatsmeow's own check runs only on Connect (prekeys.go:25-30
// in the upstream tree), so a session that stays online for days can
// drift below MinPreKeyCount (=5) and start failing new-session
// negotiations. 30 minutes is a compromise: cheap IQ, but long enough
// not to add meaningful background chatter.
const prekeyTopUpInterval = 30 * time.Minute

// prekeyLowWatermark mirrors whatsmeow's internal MinPreKeyCount. We
// trigger an upload when the server reports fewer keys than this.
// Kept as a local copy so we don't depend on the upstream identifier
// (which is exported, so this is purely defensive against rename).
const prekeyLowWatermark = whatsmeow.MinPreKeyCount

// startPrekeyTopUpLoop runs a background ticker that periodically asks
// the WhatsApp server how many prekeys it still has for us, and uploads
// a fresh batch if we've drifted below the low-watermark. Exits when
// ctx is canceled (i.e. Close()).
//
// Safe to start multiple times: each call is bound to its own ctx and
// the upload routine itself is internally locked (uploadPreKeysLock).
func (c *Client) startPrekeyTopUpLoop(ctx context.Context) {
	go func() {
		t := time.NewTicker(prekeyTopUpInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				c.maybeTopUpPreKeys(ctx)
			}
		}
	}()
}

// maybeTopUpPreKeys queries the server's prekey count and uploads a
// fresh batch if it's below the watermark. Skips silently if we're not
// connected (no useful work, plus IQ would fail).
func (c *Client) maybeTopUpPreKeys(ctx context.Context) {
	if c.wa == nil || !c.wa.IsConnected() || !c.wa.IsLoggedIn() {
		return
	}
	internals := c.wa.DangerousInternals()
	count, err := internals.GetServerPreKeyCount(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[yawac/prekey] count query failed: %v\n", err)
		return
	}
	if count >= prekeyLowWatermark {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/prekey] server count=%d below watermark=%d — uploading fresh batch\n",
		count, prekeyLowWatermark)
	// UploadPreKeys is synchronous and internally locked. initialUpload=false
	// uses the WantedPreKeyCount=50 batch size (vs. 812 for first pair).
	internals.UploadPreKeys(ctx, false)
}
