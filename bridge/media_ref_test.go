package bridge

import (
	"testing"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestMediaFromImageIncludesRef(t *testing.T) {
	m := &waE2E.ImageMessage{
		URL:           proto.String("https://example/x"),
		DirectPath:    proto.String("/dp/x"),
		MediaKey:      []byte("k"),
		FileEncSHA256: []byte("e"),
		FileSHA256:    []byte("s"),
		FileLength:    proto.Uint64(42),
		Mimetype:      proto.String("image/jpeg"),
	}
	jm := mediaFromImage(m)
	if jm.Ref == nil {
		t.Fatal("Ref nil")
	}
	if jm.Ref.URL != "https://example/x" || jm.Ref.FileLength != 42 {
		t.Fatalf("bad ref: %+v", jm.Ref)
	}
	if jm.Ref.Kind != "image" {
		t.Fatalf("bad kind: %q", jm.Ref.Kind)
	}
}
