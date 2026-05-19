package bridge

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	waLog "go.mau.fi/whatsmeow/util/log"
)

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
