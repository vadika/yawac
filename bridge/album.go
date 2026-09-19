package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"go.mau.fi/whatsmeow"
	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

type albumFile struct {
	Path string `json:"path"`
	Kind string `json:"kind"`
}

type albumSendResult struct {
	AlbumID string        `json:"album_id"`
	Items   []JSendResult `json:"items"`
	Error   string        `json:"error,omitempty"`
}

// SendAlbum sends an album envelope and media children linked to that envelope.
// A partial send returns the acknowledged children plus an error in the JSON;
// callers must not resend those children when restoring the unsent attachments.
func (c *Client) SendAlbum(chatJID, filesJSON, caption string, ephemeralSec int32) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := parseChatJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	var files []albumFile
	if err = json.Unmarshal([]byte(filesJSON), &files); err != nil {
		return "", fmt.Errorf("parse album: %w", err)
	}
	result, err := sendAlbum(context.Background(), jid, files, caption, ephemeralSec, c.wa.Upload,
		func(ctx context.Context, msg *waE2E.Message) (whatsmeow.SendResponse, error) {
			return c.wa.SendMessage(ctx, jid, msg)
		})
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(result)
	return string(out), err
}

func sendAlbum(ctx context.Context, jid types.JID, files []albumFile, caption string, ephemeralSec int32,
	upload func(context.Context, []byte, whatsmeow.MediaType) (whatsmeow.UploadResponse, error),
	send func(context.Context, *waE2E.Message) (whatsmeow.SendResponse, error),
) (albumSendResult, error) {
	result := albumSendResult{Items: []JSendResult{}}
	if len(files) < 2 {
		return result, errors.New("an album needs at least two photos or videos")
	}
	var images, videos uint32
	for _, file := range files {
		switch file.Kind {
		case "image":
			images++
		case "video":
			videos++
		default:
			return result, fmt.Errorf("unsupported album kind %q", file.Kind)
		}
	}
	// Finish uploads before publishing the envelope, so a bad file cannot
	// leave an empty album in the recipient's conversation.
	children := make([]*waE2E.Message, len(files))
	for i, file := range files {
		text := ""
		if i == 0 {
			text = caption
		}
		child, err := prepareVisualMedia(ctx, file, text, upload)
		if err != nil {
			return result, fmt.Errorf("prepare %s: %w", file.Path, err)
		}
		children[i] = child
	}
	parent := &waE2E.Message{AlbumMessage: &waE2E.AlbumMessage{
		ExpectedImageCount: proto.Uint32(images), ExpectedVideoCount: proto.Uint32(videos),
		ContextInfo: &waE2E.ContextInfo{Expiration: proto.Uint32(uint32(max(0, ephemeralSec)))},
	}}
	response, err := send(ctx, wrapForChat(parent, ephemeralSec, false))
	if err != nil {
		return result, fmt.Errorf("send album: %w", err)
	}
	result.AlbumID = response.ID
	for i, child := range children {
		child.MessageContextInfo = &waE2E.MessageContextInfo{
			MessageAssociation: &waE2E.MessageAssociation{
				AssociationType: waE2E.MessageAssociation_MEDIA_ALBUM.Enum(),
				ParentMessageKey: &waCommon.MessageKey{
					RemoteJID: proto.String(jid.String()), FromMe: proto.Bool(true), ID: proto.String(result.AlbumID),
				},
				MessageIndex: proto.Int32(int32(i)),
			},
		}
		response, err = send(ctx, wrapForChat(child, ephemeralSec, false))
		if err != nil {
			result.Error = fmt.Sprintf("send album attachment %d: %v", i+1, err)
			break
		}
		result.Items = append(result.Items, JSendResult{MessageID: response.ID, Timestamp: response.Timestamp.Unix()})
	}
	return result, nil
}

func prepareVisualMedia(ctx context.Context, file albumFile, caption string,
	upload func(context.Context, []byte, whatsmeow.MediaType) (whatsmeow.UploadResponse, error),
) (*waE2E.Message, error) {
	data, err := os.ReadFile(file.Path)
	if err != nil {
		return nil, fmt.Errorf("read file: %w", err)
	}
	up, err := upload(ctx, data, mediaTypeFor(file.Kind))
	if err != nil {
		return nil, fmt.Errorf("upload: %w", err)
	}
	if file.Kind == "image" {
		return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Caption: proto.String(caption), URL: &up.URL, DirectPath: &up.DirectPath,
			MediaKey: up.MediaKey, Mimetype: proto.String(detectImageMime(data, file.Path)),
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(uint64(len(data))),
		}}, nil
	}
	return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
		Caption: proto.String(caption), URL: &up.URL, DirectPath: &up.DirectPath,
		MediaKey: up.MediaKey, Mimetype: proto.String(detectMime(data, file.Path, "video/mp4")),
		FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
		FileLength: proto.Uint64(uint64(len(data))),
	}}, nil
}

func albumAssociation(msg *waE2E.Message) (string, *int32) {
	association := msg.GetMessageContextInfo().GetMessageAssociation()
	if association.GetAssociationType() != waE2E.MessageAssociation_MEDIA_ALBUM {
		return "", nil
	}
	return association.GetParentMessageKey().GetID(), association.MessageIndex
}
