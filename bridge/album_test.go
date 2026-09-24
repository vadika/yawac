package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func albumFiles(t *testing.T) []albumFile {
	t.Helper()
	dir := t.TempDir()
	files := []albumFile{{filepath.Join(dir, "photo.png"), "image"}, {filepath.Join(dir, "clip.mp4"), "video"}}
	for _, file := range files {
		if err := os.WriteFile(file.Path, []byte("media"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return files
}

func TestSendAlbumLinksChildrenAndPreservesCaption(t *testing.T) {
	for _, expiration := range []int32{0, 86400} {
		t.Run(fmt.Sprint(expiration), func(t *testing.T) {
			var uploaded []whatsmeow.MediaType
			var sent []*waE2E.Message
			result, err := sendAlbum(context.Background(), types.NewJID("1", types.DefaultUserServer), albumFiles(t), "Our trip", expiration,
				func(_ context.Context, _ []byte, kind whatsmeow.MediaType) (whatsmeow.UploadResponse, error) {
					uploaded = append(uploaded, kind)
					return whatsmeow.UploadResponse{URL: "https://example.test/media"}, nil
				},
				func(_ context.Context, msg *waE2E.Message) (whatsmeow.SendResponse, error) {
					if len(uploaded) != 2 {
						t.Fatal("published album before uploads completed")
					}
					if expiration > 0 {
						if msg.GetEphemeralMessage() == nil {
							t.Fatal("missing ephemeral wrapper")
						}
						msg = msg.GetEphemeralMessage().GetMessage()
					}
					sent = append(sent, msg)
					return whatsmeow.SendResponse{ID: fmt.Sprint(len(sent)), Timestamp: time.Unix(100, 0)}, nil
				})
			if err != nil {
				t.Fatal(err)
			}
			if result.AlbumID != "1" || len(result.Items) != 2 || result.Error != "" {
				t.Fatalf("result: %+v", result)
			}
			if sent[0].GetAlbumMessage().GetExpectedImageCount() != 1 || sent[0].GetAlbumMessage().GetExpectedVideoCount() != 1 {
				t.Fatal("wrong album counts")
			}
			if got := sent[0].GetAlbumMessage().GetContextInfo().GetExpiration(); got != uint32(expiration) {
				t.Fatalf("album expiration = %d, want %d", got, expiration)
			}
			if uploaded[0] != whatsmeow.MediaImage || uploaded[1] != whatsmeow.MediaVideo {
				t.Fatalf("upload types: %v", uploaded)
			}
			if sent[1].GetImageMessage().GetCaption() != "Our trip" || sent[2].GetVideoMessage().GetCaption() != "" {
				t.Fatal("caption not attached exactly once")
			}
			for i, child := range sent[1:] {
				if got := contextInfoFromMessage(child).GetExpiration(); got != uint32(expiration) {
					t.Fatalf("child expiration = %d, want %d", got, expiration)
				}
				id, index := albumAssociation(child)
				if id != "1" || index == nil || *index != int32(i) {
					t.Fatalf("association: %s %v", id, index)
				}
				key := child.GetMessageContextInfo().GetMessageAssociation().GetParentMessageKey()
				if !key.GetFromMe() || key.GetRemoteJID() != "1@s.whatsapp.net" {
					t.Fatalf("parent key: %v", key)
				}
			}
		})
	}
}

func TestSendAlbumFailurePreservesAcknowledgedChildren(t *testing.T) {
	for _, failAt := range []int{1, 2, 3} {
		t.Run(fmt.Sprint(failAt), func(t *testing.T) {
			calls := 0
			result, err := sendAlbum(context.Background(), types.NewJID("1", types.DefaultUserServer), albumFiles(t), "caption", 0,
				func(context.Context, []byte, whatsmeow.MediaType) (whatsmeow.UploadResponse, error) {
					return whatsmeow.UploadResponse{}, nil
				},
				func(context.Context, *waE2E.Message) (whatsmeow.SendResponse, error) {
					calls++
					if calls == failAt {
						return whatsmeow.SendResponse{}, errors.New("offline")
					}
					return whatsmeow.SendResponse{ID: fmt.Sprint(calls)}, nil
				})
			if calls != failAt {
				t.Fatal("continued sending after failure")
			}
			if failAt == 1 {
				if err == nil {
					t.Fatal("expected envelope error")
				}
			} else if err != nil || result.Error == "" || len(result.Items) != failAt-2 {
				t.Fatalf("partial result: %+v, error %v", result, err)
			}
		})
	}
}

func TestSendAlbumRejectsInvalidInputBeforeSending(t *testing.T) {
	valid := albumFiles(t)
	for _, files := range [][]albumFile{nil, valid[:1], {valid[0], {Path: valid[1].Path, Kind: "audio"}}, {valid[0], {Path: "/missing", Kind: "image"}}} {
		_, err := sendAlbum(context.Background(), types.NewJID("1", types.DefaultUserServer), files, "", 0,
			func(context.Context, []byte, whatsmeow.MediaType) (whatsmeow.UploadResponse, error) {
				return whatsmeow.UploadResponse{}, nil
			},
			func(context.Context, *waE2E.Message) (whatsmeow.SendResponse, error) {
				t.Fatal("sent invalid album")
				return whatsmeow.SendResponse{}, nil
			})
		if err == nil {
			t.Fatal("expected validation error")
		}
	}
}

func TestAlbumAssociationSurvivesLiveAndHistoryDispatch(t *testing.T) {
	chat := types.NewJID("12345", types.DefaultUserServer)
	child := &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{Caption: proto.String("Caption")},
		MessageContextInfo: &waE2E.MessageContextInfo{MessageAssociation: &waE2E.MessageAssociation{
			AssociationType:  waE2E.MessageAssociation_MEDIA_ALBUM.Enum(),
			ParentMessageKey: &waCommon.MessageKey{ID: proto.String("album")},
			MessageIndex:     proto.Int32(0),
		}},
	}
	for _, source := range []string{"live", "history", "ephemeral history"} {
		t.Run(source, func(t *testing.T) {
			c := &Client{}
			sink := newRecSink()
			c.SetEventSink(sink)
			if source == "live" {
				c.dispatchMessage(&events.Message{
					Info:    types.MessageInfo{MessageSource: types.MessageSource{Chat: chat, Sender: chat}, ID: "child"},
					Message: child,
				})
			} else {
				payload := child
				if source == "ephemeral history" {
					payload = wrapForChat(child, 86400, false)
				}
				c.dispatchWebMessage(chat.String(), &waWeb.WebMessageInfo{
					Key:     &waCommon.MessageKey{ID: proto.String("child"), RemoteJID: proto.String(chat.String())},
					Message: payload,
				})
			}
			var got JMessage
			if err := json.Unmarshal([]byte(sink.wait(t, "Message", time.Second).payload), &got); err != nil {
				t.Fatal(err)
			}
			if got.AlbumID != "album" || got.AlbumIndex == nil || *got.AlbumIndex != 0 || got.Kind != "image" || got.Media.Caption != "Caption" {
				t.Fatalf("lost album metadata: %+v", got)
			}
		})
	}
}

func TestNonAlbumAssociationsDoNotGroupMedia(t *testing.T) {
	msg := &waE2E.Message{MessageContextInfo: &waE2E.MessageContextInfo{MessageAssociation: &waE2E.MessageAssociation{
		AssociationType:  waE2E.MessageAssociation_EVENT_COVER_IMAGE.Enum(),
		ParentMessageKey: &waCommon.MessageKey{ID: proto.String("event")},
	}}}
	if id, index := albumAssociation(msg); id != "" || index != nil {
		t.Fatal("grouped a non-album association")
	}
	if id, index := albumAssociation(nil); id != "" || index != nil {
		t.Fatal("grouped a missing association")
	}
}
