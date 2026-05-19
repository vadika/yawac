package bridge

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

// FetchProfilePicture downloads the preview avatar for `jidStr` to `outPath`.
// Returns the same outPath on success. Returns "" with a nil error when the
// user has no profile picture (don't treat that as an error in Swift).
func (c *Client) FetchProfilePicture(jidStr, outPath string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	if jid.User == "" {
		return "", fmt.Errorf("parse jid: %q invalid", jidStr)
	}

	info, err := c.wa.GetProfilePictureInfo(context.Background(), jid,
		&whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil {
		// Common case: ErrProfilePictureUnauthorized → privacy-restricted.
		// Treat as no picture available (empty path).
		return "", nil
	}
	if info == nil || info.URL == "" {
		return "", nil
	}

	httpClient := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", info.URL, nil)
	if err != nil {
		return "", fmt.Errorf("new req: %w", err)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("http get: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("http status %d", resp.StatusCode)
	}

	if err := os.MkdirAll(filepath.Dir(outPath), 0o700); err != nil {
		return "", fmt.Errorf("mkdir: %w", err)
	}
	f, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", fmt.Errorf("open file: %w", err)
	}
	defer f.Close()
	if _, err := io.Copy(f, resp.Body); err != nil {
		os.Remove(outPath)
		return "", fmt.Errorf("write: %w", err)
	}
	return outPath, nil
}
