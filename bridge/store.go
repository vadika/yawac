package bridge

import (
	"context"
	"fmt"

	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	waLog "go.mau.fi/whatsmeow/util/log"

	_ "modernc.org/sqlite"
)

func openContainer(dbPath string) (*sqlstore.Container, error) {
	// F84 / issue #6: add `busy_timeout=5000` so concurrent writers wait
	// up to 5s for the lock instead of immediately returning
	// SQLITE_BUSY. Without it, decryption + history-sync + identity-save
	// goroutines race for the writer slot and the loser drops the
	// in-flight message. Symptom: prekey-message decryption fails
	// (`failed to save identity ... database is locked (5)`), the
	// originating Message event never fires, the message is missing
	// from yawac after offline-period reconnect — issue #6.
	//
	// `synchronous=NORMAL` is the safe WAL pairing (still durable across
	// app crash; only at risk on power loss within the WAL checkpoint
	// window). Whatsmeow store losses on power loss are acceptable —
	// the phone has the canonical copy.
	dsn := fmt.Sprintf(
		"file:%s?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)"+
			"&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)",
		dbPath)
	log := waLog.Stdout("sqlstore", "INFO", true)
	ctx, cancel := context.WithCancel(context.Background())
	_ = cancel // container retains its own context internally
	return sqlstore.New(ctx, "sqlite", dsn, log)
}

func firstDevice(ctx context.Context, c *sqlstore.Container) (*store.Device, error) {
	dev, err := c.GetFirstDevice(ctx)
	if err != nil {
		return nil, fmt.Errorf("get device: %w", err)
	}
	return dev, nil
}
