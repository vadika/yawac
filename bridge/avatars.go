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
	if info == nil {
		alt, ok := c.alternateProfileJID(jid)
		if ok {
			if altInfo, _ := c.tryProfilePictureInfo(alt); altInfo != nil {
				info = altInfo
			}
		}
	}
	if info == nil {
		if infoErr != nil {
			fmt.Fprintf(os.Stderr,
				"[yawac/avatar] fetch %s: no picture (err: %v)\n",
				jid, infoErr)
		} else {
			fmt.Fprintf(os.Stderr,
				"[yawac/avatar] fetch %s: no picture (empty info)\n", jid)
		}
		return "", nil
	}
	if info.URL == "" {
		fmt.Fprintf(os.Stderr,
			"[yawac/avatar] fetch %s: info returned but empty URL\n", jid)
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
