package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/whatsmeow"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// detectImageMime sniffs the first 512 bytes of data and, failing that,
// falls back to the file extension. Default is image/jpeg.
func detectImageMime(data []byte, filePath string) string {
	if len(data) > 0 {
		mime := http.DetectContentType(data[:min(512, len(data))])
		if strings.HasPrefix(mime, "image/") {
			return mime
		}
	}
	switch strings.ToLower(filepath.Ext(filePath)) {
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	default:
		return "image/jpeg"
	}
}

// detectMime sniffs the first 512 bytes, falls back to the file extension,
// then to the supplied fallback.
func detectMime(data []byte, filePath string, fallback string) string {
	if len(data) > 0 {
		sniffed := http.DetectContentType(data[:min(512, len(data))])
		if sniffed != "application/octet-stream" && sniffed != "" {
			return sniffed
		}
	}
	if mime := mimeFromExt(filePath); mime != "" {
		return mime
	}
	return fallback
}

func mimeFromExt(filePath string) string {
	switch strings.ToLower(filepath.Ext(filePath)) {
	case ".mp4":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	case ".mp3":
		return "audio/mpeg"
	case ".ogg":
		return "audio/ogg"
	case ".m4a":
		return "audio/mp4"
	case ".wav":
		return "audio/wav"
	case ".pdf":
		return "application/pdf"
	case ".doc":
		return "application/msword"
	case ".docx":
		return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	case ".xls":
		return "application/vnd.ms-excel"
	case ".xlsx":
		return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	case ".zip":
		return "application/zip"
	case ".txt":
		return "text/plain"
	default:
		return ""
	}
}

// SendImage reads a local file, uploads it to WhatsApp, and sends an
// ImageMessage to the given chat. Returns JSON of JSendResult.
func (c *Client) SendImage(chatJID, filePath, caption string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	up, err := c.wa.Upload(context.Background(), data, whatsmeow.MediaImage)
	if err != nil {
		return "", fmt.Errorf("upload: %w", err)
	}

	mime := detectImageMime(data, filePath)
	msg := &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
		Caption:       proto.String(caption),
		URL:           &up.URL,
		DirectPath:    &up.DirectPath,
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String(mime),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(uint64(len(data))),
	}}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send image: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// SendVideo uploads filePath as a VideoMessage. Mime auto-detected.
func (c *Client) SendVideo(chatJID, filePath, caption string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	up, err := c.wa.Upload(context.Background(), data, whatsmeow.MediaVideo)
	if err != nil {
		return "", fmt.Errorf("upload: %w", err)
	}

	mime := detectMime(data, filePath, "video/mp4")
	msg := &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
		Caption:       proto.String(caption),
		URL:           &up.URL,
		DirectPath:    &up.DirectPath,
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String(mime),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(uint64(len(data))),
	}}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send video: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// SendAudio uploads filePath as an AudioMessage. Mime auto-detected.
func (c *Client) SendAudio(chatJID, filePath string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	up, err := c.wa.Upload(context.Background(), data, whatsmeow.MediaAudio)
	if err != nil {
		return "", fmt.Errorf("upload: %w", err)
	}

	mime := detectMime(data, filePath, "audio/ogg")
	msg := &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
		URL:           &up.URL,
		DirectPath:    &up.DirectPath,
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String(mime),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(uint64(len(data))),
	}}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send audio: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// SendDocument uploads filePath as a DocumentMessage with caption + filename.
// Mime auto-detected; falls back to application/octet-stream.
func (c *Client) SendDocument(chatJID, filePath, caption string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	up, err := c.wa.Upload(context.Background(), data, whatsmeow.MediaDocument)
	if err != nil {
		return "", fmt.Errorf("upload: %w", err)
	}

	mime := detectMime(data, filePath, "application/octet-stream")
	fileName := filepath.Base(filePath)
	msg := &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
		Caption:       proto.String(caption),
		FileName:      proto.String(fileName),
		URL:           &up.URL,
		DirectPath:    &up.DirectPath,
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String(mime),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(uint64(len(data))),
	}}
	resp, err := c.wa.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return "", fmt.Errorf("send document: %w", err)
	}
	out, _ := json.Marshal(JSendResult{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()})
	return string(out), nil
}

// MediaRef is the JSON shape Swift passes to request a download.
// Fields mirror whatsmeow.DownloadableMessage's required attributes.
type MediaRef struct {
	Kind          string `json:"kind"` // image, video, audio, document, sticker
	URL           string `json:"url"`
	DirectPath    string `json:"direct_path"`
	MediaKey      []byte `json:"media_key"`
	FileEncSHA256 []byte `json:"file_enc_sha256"`
	FileSHA256    []byte `json:"file_sha256"`
	FileLength    uint64 `json:"file_length"`
	Mimetype      string `json:"mimetype"`
}

// DownloadMedia parses a MediaRef JSON, downloads the encrypted media via
// whatsmeow, and writes the plaintext bytes to outPath. Returns outPath.
func (c *Client) DownloadMedia(refJSON, outPath string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	var r MediaRef
	if err := json.Unmarshal([]byte(refJSON), &r); err != nil {
		return "", fmt.Errorf("parse ref: %w", err)
	}
	var dl whatsmeow.DownloadableMessage
	switch r.Kind {
	case "image":
		dl = &waE2E.ImageMessage{URL: &r.URL, DirectPath: &r.DirectPath, MediaKey: r.MediaKey,
			FileEncSHA256: r.FileEncSHA256, FileSHA256: r.FileSHA256,
			FileLength: &r.FileLength, Mimetype: &r.Mimetype}
	case "video":
		dl = &waE2E.VideoMessage{URL: &r.URL, DirectPath: &r.DirectPath, MediaKey: r.MediaKey,
			FileEncSHA256: r.FileEncSHA256, FileSHA256: r.FileSHA256,
			FileLength: &r.FileLength, Mimetype: &r.Mimetype}
	case "audio":
		dl = &waE2E.AudioMessage{URL: &r.URL, DirectPath: &r.DirectPath, MediaKey: r.MediaKey,
			FileEncSHA256: r.FileEncSHA256, FileSHA256: r.FileSHA256,
			FileLength: &r.FileLength, Mimetype: &r.Mimetype}
	case "document":
		dl = &waE2E.DocumentMessage{URL: &r.URL, DirectPath: &r.DirectPath, MediaKey: r.MediaKey,
			FileEncSHA256: r.FileEncSHA256, FileSHA256: r.FileSHA256,
			FileLength: &r.FileLength, Mimetype: &r.Mimetype}
	case "sticker":
		dl = &waE2E.StickerMessage{URL: &r.URL, DirectPath: &r.DirectPath, MediaKey: r.MediaKey,
			FileEncSHA256: r.FileEncSHA256, FileSHA256: r.FileSHA256,
			FileLength: &r.FileLength, Mimetype: &r.Mimetype}
	default:
		return "", fmt.Errorf("unknown kind %q", r.Kind)
	}
	data, err := c.wa.Download(context.Background(), dl)
	if err != nil {
		return "", fmt.Errorf("download: %w", err)
	}
	if err := os.WriteFile(outPath, data, 0o600); err != nil {
		return "", fmt.Errorf("write: %w", err)
	}
	return outPath, nil
}
