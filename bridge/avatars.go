package bridge

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

var (
	avatarLogMu      sync.Mutex
	avatarLogEnabled = os.Getenv("YAWAC_AVATAR_LOG") == "1"
)

// avatarLog appends to /tmp/yawac-avatar.log alongside the Swift-side
// AvatarLog when YAWAC_AVATAR_LOG=1 is set. stderr in a gomobile-bound
// binary is captured by macOS unified logging with privacy redaction —
// a plain file is the shortest path to readable diagnostics.
func avatarLog(format string, args ...any) {
	if !avatarLogEnabled {
		return
	}
	avatarLogMu.Lock()
	defer avatarLogMu.Unlock()
	f, err := os.OpenFile("/tmp/yawac-avatar.log",
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, format+"\n", args...)
}

// FetchProfilePicture downloads the preview avatar for `jidStr` to `outPath`.
// Returns the same outPath on success. Returns "" with a nil error when the
// user has no profile picture (don't treat that as an error in Swift).
//
// Tries the original JID first. When that returns empty / unauthorized AND
// the JID is a phone number, also tries the LID form via Store.LIDs.GetLIDForPN
// — WhatsApp may have migrated the contact to privacy-LID and store the
// picture only against the LID identity. The mirror also runs (LID → PN).
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

	info, infoErr := c.tryProfilePictureInfo(jid)
	avatarLog("[avatar] %s primary: info=%v err=%v", jid, info != nil, infoErr)

	if info == nil {
		alt, ok := c.alternateProfileJID(jid)
		if ok {
			altInfo, altErr := c.tryProfilePictureInfo(alt)
			avatarLog("[avatar] %s alt=%s: info=%v err=%v",
				jid, alt, altInfo != nil, altErr)
			if altInfo != nil {
				info = altInfo
			}
		} else {
			// No mapping known yet. Force populate via GetUserInfo,
			// which surfaces a <lid> tag the store consumes as a side
			// effect, then retry the alt path.
			ui, uiErr := c.wa.GetUserInfo(context.Background(),
				[]types.JID{jid})
			avatarLog("[avatar] %s GetUserInfo: rows=%d err=%v",
				jid, len(ui), uiErr)
			if uiErr == nil {
				alt2, ok2 := c.alternateProfileJID(jid)
				avatarLog("[avatar] %s alt2 after GetUserInfo: ok=%v jid=%s",
					jid, ok2, alt2)
				if ok2 {
					altInfo, altErr := c.tryProfilePictureInfo(alt2)
					avatarLog("[avatar] %s alt2-fetch: info=%v err=%v",
						jid, altInfo != nil, altErr)
					if altInfo != nil {
						info = altInfo
					}
				}
			}
		}
	}
	if info == nil {
		avatarLog("[avatar] %s: no picture available", jid)
		return "", nil
	}
	if info.URL == "" {
		avatarLog("[avatar] %s: info has empty URL", jid)
		return "", nil
	}
	avatarLog("[avatar] %s: downloading %s", jid, info.URL)

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

// tryProfilePictureInfo runs GetProfilePictureInfo without converting errors
// into nil — caller logs the error if both forms fail.
func (c *Client) tryProfilePictureInfo(jid types.JID) (*types.ProfilePictureInfo, error) {
	info, err := c.wa.GetProfilePictureInfo(context.Background(), jid,
		&whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil {
		return nil, err
	}
	return info, nil
}

// alternateProfileJID returns the LID form for a PN JID (or PN for LID)
// via the local Store.LIDs map. Returns ok=false when no mapping is known
// or the JID isn't a user JID.
func (c *Client) alternateProfileJID(jid types.JID) (types.JID, bool) {
	if c.wa == nil || c.wa.Store == nil || c.wa.Store.LIDs == nil {
		return types.JID{}, false
	}
	switch jid.Server {
	case types.DefaultUserServer:
		lid, err := c.wa.Store.LIDs.GetLIDForPN(context.Background(), jid)
		if err == nil && !lid.IsEmpty() {
			return lid, true
		}
	case types.HiddenUserServer:
		pn, err := c.wa.Store.LIDs.GetPNForLID(context.Background(), jid)
		if err == nil && !pn.IsEmpty() {
			return pn, true
		}
	}
	return types.JID{}, false
}
