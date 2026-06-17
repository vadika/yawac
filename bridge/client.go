package bridge

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

// applyDeeperHistorySyncDefaults overrides whatsmeow's stock
// store.DeviceProps to ask the phone for substantially more history
// than the default RECENT bootstrap. Phone-side default ships ~3
// messages per chat from a single INITIAL_BOOTSTRAP chunk with
// progress=100 — confirmed via the F-instr trace 2026-06-09
// (sync_type=INITIAL_BOOTSTRAP total_msgs=621 across 211 chats).
//
// These flags only matter at the FIRST pair (or after Logout +
// re-pair). Existing pairings already settled on the conservative
// defaults; they'd need to re-pair to feel the difference.
//
// Called from init() so the override lands before any
// whatsmeow.NewClient call.
func applyDeeperHistorySyncDefaults() {
	// RequireFullSync flips the phone from "ship RECENT" to "ship FULL".
	store.DeviceProps.RequireFullSync = proto.Bool(true)
	cfg := store.DeviceProps.HistorySyncConfig
	if cfg == nil {
		return
	}
	// Cap the full sync at 10 years and 2 GB so a comically large
	// account doesn't try to transfer the universe. Phone enforces its
	// own ceiling below these in practice.
	cfg.FullSyncDaysLimit = proto.Uint32(3650)
	cfg.FullSyncSizeMbLimit = proto.Uint32(2048)
	// Advertise on-demand support so the phone honors
	// BuildHistorySyncRequest / FULL_HISTORY_SYNC_ON_DEMAND.
	cfg.OnDemandReady = proto.Bool(true)
	cfg.CompleteOnDemandReady = proto.Bool(true)
}

// applyYawacBrand overrides whatsmeow's stock DeviceProps Os +
// PlatformType so the phone's linked-devices list shows "yawac" with
// a macOS desktop icon instead of "whatsmeow · other platform · other
// device". F86. Phone-side reads Os as the human-visible device name
// and PlatformType drives the icon — CATALINA = 12 is WhatsApp
// Desktop's own macOS slot, the closest match for a native macOS
// companion.
//
// Only matters at FIRST pair (or after Logout + re-pair). Existing
// pairings are stuck with whatever they registered.
func applyYawacBrand() {
	store.DeviceProps.Os = proto.String("yawac")
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CATALINA.Enum()
}

// redirectStderr is run once at package init so logs (whatsmeow's
// chatty INFO/WARN stream + our own fprintf traces) survive when the
// app is launched via LaunchServices (`open`), which otherwise routes
// stderr to /dev/null. Append-mode so multiple launches accumulate.
//
// Skipped when running under `go test` — the redirect swallows test
// output and makes CI failures invisible. Detected via the test binary
// suffix that the Go toolchain produces.
func init() {
	if strings.HasSuffix(os.Args[0], ".test") ||
		strings.Contains(os.Args[0], "/_test/") {
		return
	}
	const logPath = "/tmp/yawac.log"
	f, err := os.OpenFile(logPath,
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	_ = syscall.Dup2(int(f.Fd()), int(os.Stderr.Fd()))
	_ = syscall.Dup2(int(f.Fd()), int(os.Stdout.Fd()))
	fmt.Fprintf(os.Stderr,
		"[yawac] === bridge init %s ===\n",
		time.Now().Format(time.RFC3339))
	// Override whatsmeow's default DeviceProps to ask the phone for
	// deep history at pair time. Must run BEFORE any whatsmeow.NewClient
	// call — DeviceProps is a package-level singleton consulted at
	// registration.
	applyDeeperHistorySyncDefaults()
	// F86: brand the linked-device entry as "yawac · macOS" instead
	// of "whatsmeow · other platform".
	applyYawacBrand()
}

// Client wraps a *whatsmeow.Client and is the primary handle exposed to Swift.
type Client struct {
	mu     sync.Mutex
	wa     *whatsmeow.Client
	sink   EventSink
	cancel context.CancelFunc
	dbPath string

	// pendingRetry tracks in-flight media retry requests, keyed by message
	// ID, so we can resume a download once the phone sends back the new
	// DirectPath via *events.MediaRetry. Process-local only (not persisted).
	retryMu      sync.Mutex
	pendingRetry map[string]MediaRef

	// mediaConnMu serializes force-refreshes of the media connection so a
	// burst of concurrent download failures doesn't trigger N refreshes and
	// trip WhatsApp's 429 rate limiter. lastForceRefresh records the most
	// recent successful force refresh; calls within mediaConnCooldown are
	// no-ops that simply succeed.
	mediaConnMu       sync.Mutex
	lastForceRefresh  time.Time

	// F83: tracks an in-flight OfflineSync drain so we can compare what
	// the server announced via OfflineSyncPreview against what actually
	// arrives as *events.Message / *events.Receipt before
	// OfflineSyncCompleted. Issue #6.
	offlineDrain offlineDrainTracker
}

const mediaConnCooldown = 30 * time.Second

// refreshMediaConnRateLimited force-refreshes the media connection at most
// once per cooldown window. Returns nil if a refresh either just ran or was
// skipped because one ran recently.
func (c *Client) refreshMediaConnRateLimited() error {
	c.mediaConnMu.Lock()
	defer c.mediaConnMu.Unlock()
	if time.Since(c.lastForceRefresh) < mediaConnCooldown {
		return nil
	}
	if _, err := c.wa.DangerousInternals().RefreshMediaConn(context.Background(), true); err != nil {
		return err
	}
	c.lastForceRefresh = time.Now()
	return nil
}

// NewClient initializes a SQLite-backed bridge Client at dbPath.
// It does NOT connect to WhatsApp servers — call Connect for that.
func NewClient(dbPath string) (*Client, error) {
	if dbPath == "" {
		return nil, errors.New("dbPath required")
	}
	container, err := openContainer(dbPath)
	if err != nil {
		return nil, fmt.Errorf("open container: %w", err)
	}
	dev, err := firstDevice(context.Background(), container)
	if err != nil {
		return nil, err
	}
	log := waLog.Stdout("whatsmeow", "INFO", true)
	wa := whatsmeow.NewClient(dev, log)
	// Keep an in-memory copy of outgoing messages so retry receipts
	// received shortly after a restart can still be served instead of
	// being dropped. See docs/TODO.md: "Should enable
	// Client.UseRetryMessageStore = true to survive restarts during
	// retry windows."
	wa.UseRetryMessageStore = true
	// Surface appstate events (pin, star, mute, archive, delete-for-me)
	// during full-sync replays. Without this, pin/star state set on
	// the phone before this device connected — or replayed after a
	// fresh device link — never reaches the Swift side, leaving the
	// sidebar/menu stuck in their default state.
	wa.EmitAppStateEventsOnFullSync = true
	return &Client{
		wa:           wa,
		dbPath:       dbPath,
		pendingRetry: map[string]MediaRef{},
	}, nil
}

// Close disconnects and releases resources.
func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	if c.wa != nil {
		c.wa.Disconnect()
	}
}

// Reconnect forces a clean socket cycle. Calls whatsmeow's
// Disconnect/Connect directly (NOT the bridge Connect wrapper) so the
// event handler + prekey loop registered on first Connect aren't
// duplicated — handlers live on the Client, not the socket, so they
// persist across cycles. Disconnect sets whatsmeow's expectedDisconnect
// flag so its own auto-reconnect goroutine won't race us.
func (c *Client) Reconnect() error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	if c.wa.Store.ID == nil {
		return nil // unpaired → QR/pair flow owns connect
	}
	fmt.Fprintf(os.Stderr, "[yawac/reconnect] forced; wasConnected=%v\n", c.wa.IsConnected())
	c.wa.Disconnect()
	err := c.wa.Connect()
	fmt.Fprintf(os.Stderr, "[yawac/reconnect] connect returned err=%v nowConnected=%v\n", err, c.wa.IsConnected())
	return err
}

// IsConnected reports whether the websocket is currently up. Note: after
// a macOS sleep the socket can be half-open and this returns a stale
// true — callers that must recover from sleep should force a reconnect
// rather than gating on this.
func (c *Client) IsConnected() bool {
	return c.wa != nil && c.wa.IsConnected()
}

// IsLoggedIn reports whether the underlying device has registration creds.
func (c *Client) IsLoggedIn() bool {
	return c.wa != nil && c.wa.Store.ID != nil
}

// OwnJID returns the bare (non-AD) JID of this device's account, or
// "" if not logged in. Used by Swift to attribute optimistic poll
// votes / reactions so they don't double-tally against the phone's
// echo (which arrives with the account's real JID, not "me").
func (c *Client) OwnJID() string {
	if c.wa == nil || c.wa.Store == nil || c.wa.Store.ID == nil {
		return ""
	}
	return c.wa.Store.ID.ToNonAD().String()
}
