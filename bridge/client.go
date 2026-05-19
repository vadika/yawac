package bridge

import (
	"context"
	"errors"
	"fmt"
	"sync"

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
