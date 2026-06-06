package bridge

import (
	"encoding/base64"
	"strings"
	"testing"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestSendImageMissingFile(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/im.db")
	defer c.Close()
	_, err := c.SendImage("1@s.whatsapp.net", "/no/such/file.jpg", "caption", 0, false)
	if err == nil || !strings.Contains(err.Error(), "read file") {
		t.Fatalf("want read file error, got %v", err)
	}
}

// TestMediaFromAudioCarriesWaveform asserts mediaFromAudio surfaces the
// AudioMessage.Waveform proto field as base64 + the PTT flag so the Swift
// side can render the WhatsApp-style amplitude bars on inbound voice notes.
func TestMediaFromAudioCarriesWaveform(t *testing.T) {
	wave := []byte{0, 25, 50, 75, 100, 100, 75, 50, 25, 0}
	am := &waE2E.AudioMessage{
		Mimetype: proto.String("audio/ogg; codecs=opus"),
		Seconds:  proto.Uint32(3),
		PTT:      proto.Bool(true),
		Waveform: wave,
	}
	jm := mediaFromAudio(am)
	if jm == nil {
		t.Fatal("mediaFromAudio returned nil")
	}
	want := base64.StdEncoding.EncodeToString(wave)
	if jm.Waveform != want {
		t.Fatalf("waveform mismatch: got %q want %q", jm.Waveform, want)
	}
	if !jm.IsPTT {
		t.Fatal("expected IsPTT=true for PTT audio")
	}
}

// TestMediaFromAudioOmitsEmptyWaveform guards the empty-waveform path —
// older / non-PTT clips shouldn't produce a stray base64 of nothing.
func TestMediaFromAudioOmitsEmptyWaveform(t *testing.T) {
	am := &waE2E.AudioMessage{
		Mimetype: proto.String("audio/mpeg"),
		Seconds:  proto.Uint32(10),
	}
	jm := mediaFromAudio(am)
	if jm.Waveform != "" {
		t.Fatalf("expected empty waveform, got %q", jm.Waveform)
	}
	if jm.IsPTT {
		t.Fatal("expected IsPTT=false when PTT proto field unset")
	}
}
