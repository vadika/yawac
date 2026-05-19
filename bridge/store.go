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
	dsn := fmt.Sprintf("file:%s?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)", dbPath)
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
