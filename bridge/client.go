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
	waLog "go.mau.fi/whatsmeow/util/log"
)

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
