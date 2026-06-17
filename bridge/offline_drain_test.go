package bridge

import (
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func TestOfflineDrainTrackerTicksUndecryptableUnavailable(t *testing.T) {
	tracker := &offlineDrainTracker{}
	tracker.start(1, 0, 0, 0, 0)

	evt := &events.UndecryptableMessage{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:   types.NewJID("12345", types.DefaultUserServer),
				Sender: types.NewJID("12345", types.DefaultUserServer),
			},
			ID:        "test-msg-id",
			Timestamp: time.Now(),
		},
		IsUnavailable: true,
	}
	tracker.tickUndecryptable(evt)

	counts := tracker.stop()
	if counts.undecryptable != 1 {
		t.Errorf("undecryptable=%d, want 1", counts.undecryptable)
	}
	if counts.undecryptableUnavail != 1 {
		t.Errorf("undecryptableUnavail=%d, want 1", counts.undecryptableUnavail)
	}
	if counts.undecryptableCiphertext != 0 {
		t.Errorf("undecryptableCiphertext=%d, want 0", counts.undecryptableCiphertext)
	}
}

func TestOfflineDrainTrackerTicksUndecryptableCiphertext(t *testing.T) {
	tracker := &offlineDrainTracker{}
	tracker.start(1, 0, 0, 0, 0)

	evt := &events.UndecryptableMessage{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:   types.NewJID("12345", types.DefaultUserServer),
				Sender: types.NewJID("12345", types.DefaultUserServer),
			},
			ID:        "test-msg-id",
			Timestamp: time.Now(),
		},
		IsUnavailable: false,
	}
	tracker.tickUndecryptable(evt)

	counts := tracker.stop()
	if counts.undecryptable != 1 {
		t.Errorf("undecryptable=%d, want 1", counts.undecryptable)
	}
	if counts.undecryptableUnavail != 0 {
		t.Errorf("undecryptableUnavail=%d, want 0", counts.undecryptableUnavail)
	}
	if counts.undecryptableCiphertext != 1 {
		t.Errorf("undecryptableCiphertext=%d, want 1", counts.undecryptableCiphertext)
	}
}

func TestOfflineDrainTrackerIgnoresOutsideInFlight(t *testing.T) {
	tracker := &offlineDrainTracker{}
	// NOT starting — so inFlight is false.

	evt := &events.UndecryptableMessage{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:   types.NewJID("12345", types.DefaultUserServer),
				Sender: types.NewJID("12345", types.DefaultUserServer),
			},
			ID:        "test-msg-id",
			Timestamp: time.Now(),
		},
		IsUnavailable: true,
	}
	tracker.tickUndecryptable(evt)

	counts := tracker.stop()
	if counts.undecryptable != 0 {
		t.Errorf("undecryptable=%d, want 0 (outside in-flight)", counts.undecryptable)
	}
}
