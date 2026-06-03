package bridge

import (
	"strings"
	"testing"
)

func TestSendVideoMissingFile(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sv.db")
	defer c.Close()
	_, err := c.SendVideo("1@s.whatsapp.net", "/no/such.mp4", "", 0, false)
	if err == nil || !strings.Contains(err.Error(), "read file") {
		t.Fatalf("got %v", err)
	}
}

func TestSendAudioMissingFile(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sa.db")
	defer c.Close()
	_, err := c.SendAudio("1@s.whatsapp.net", "/no/such.mp3", 0)
	if err == nil || !strings.Contains(err.Error(), "read file") {
		t.Fatalf("got %v", err)
	}
}

func TestSendDocumentMissingFile(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/sd.db")
	defer c.Close()
	_, err := c.SendDocument("1@s.whatsapp.net", "/no/such.pdf", "", 0)
	if err == nil || !strings.Contains(err.Error(), "read file") {
		t.Fatalf("got %v", err)
	}
}

func TestDetectImageMimeJPEGHeader(t *testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0}
	if mime := detectImageMime(jpeg, "x"); mime != "image/jpeg" {
		t.Fatalf("got %s", mime)
	}
}

func TestDetectImageMimePNGHeader(t *testing.T) {
	png := []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}
	if mime := detectImageMime(png, "x"); mime != "image/png" {
		t.Fatalf("got %s", mime)
	}
}
