package bridge

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types/events"
)

// offlineLogPath is a stable file the Swift-launched binary can append
// diagnostic lines to without relying on stderr (which macOS detaches
// from GUI apps launched via Launch Services / `open`).
var offlineLogPath = filepath.Join(os.TempDir(), "yawac-offline.log")

func offlineLog(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	if f, err := os.OpenFile(offlineLogPath,
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		fmt.Fprintf(f, "[%s] %s\n",
			time.Now().Format("15:04:05.000"), line)
		_ = f.Close()
	}
	fmt.Fprintln(os.Stderr, "[yawac/offline] "+line)
}

// offlineDrainTracker records the in-flight offline-sync window between
// *events.OfflineSyncPreview and *events.OfflineSyncCompleted so we can
// see whether server-announced offline messages actually arrive as
// *events.Message events at the bridge. Issue #6 / F83.
type offlineDrainTracker struct {
	mu       sync.Mutex
	inFlight bool
	startedAt time.Time

	announcedTotal         int
	announcedAppData       int
	announcedMessages      int
	announcedNotifications int
	announcedReceipts      int

	gotMessages int
	gotReceipts int
}

type offlineDrainCounts struct {
	messages int
	receipts int
}

func (t *offlineDrainTracker) start(total, appdata, messages, notifications, receipts int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.inFlight = true
	t.startedAt = time.Now()
	t.announcedTotal = total
	t.announcedAppData = appdata
	t.announcedMessages = messages
	t.announcedNotifications = notifications
	t.announcedReceipts = receipts
	t.gotMessages = 0
	t.gotReceipts = 0
}

func (t *offlineDrainTracker) stop() offlineDrainCounts {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := offlineDrainCounts{messages: t.gotMessages, receipts: t.gotReceipts}
	t.inFlight = false
	return out
}

func (t *offlineDrainTracker) tickMessage(evt *events.Message) {
	t.mu.Lock()
	if !t.inFlight {
		t.mu.Unlock()
		return
	}
	t.gotMessages++
	idx := t.gotMessages
	t.mu.Unlock()
	offlineLog("msg #%d chat=%s sender=%s ts=%d id=%s isEdit=%v isEphemeral=%v",
		idx,
		evt.Info.Chat.String(),
		evt.Info.Sender.String(),
		evt.Info.Timestamp.Unix(),
		evt.Info.ID,
		evt.IsEdit,
		evt.IsEphemeral,
	)
}

func (t *offlineDrainTracker) tickReceipt(evt *events.Receipt) {
	t.mu.Lock()
	if !t.inFlight {
		t.mu.Unlock()
		return
	}
	t.gotReceipts++
	idx := t.gotReceipts
	t.mu.Unlock()
	offlineLog("receipt #%d chat=%s sender=%s type=%s msgIDs=%v",
		idx,
		evt.Chat.String(),
		evt.Sender.String(),
		evt.Type,
		evt.MessageIDs,
	)
}
