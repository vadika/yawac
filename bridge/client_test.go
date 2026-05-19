package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewClientCreatesStore(t *testing.T) {
	dir := t.TempDir()
	c, err := NewClient(filepath.Join(dir, "yawac.db"))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if c == nil {
		t.Fatal("NewClient returned nil client")
	}
	defer c.Close()

	if _, err := os.Stat(filepath.Join(dir, "yawac.db")); err != nil {
		t.Fatalf("expected db file: %v", err)
	}
}
