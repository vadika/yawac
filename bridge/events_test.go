package bridge

import (
	"sync"
	"testing"
	"time"
)

type recSink struct {
	mu     sync.Mutex
	events []recEvent
	ch     chan struct{}
}
type recEvent struct{ kind, payload string }

func newRecSink() *recSink { return &recSink{ch: make(chan struct{}, 16)} }

func (r *recSink) OnEvent(kind, payload string) {
	r.mu.Lock()
	r.events = append(r.events, recEvent{kind, payload})
	r.mu.Unlock()
	select {
	case r.ch <- struct{}{}:
	default:
	}
}

func (r *recSink) wait(t *testing.T, kind string, d time.Duration) recEvent {
	t.Helper()
	deadline := time.After(d)
	for {
		select {
		case <-r.ch:
			r.mu.Lock()
			for i, e := range r.events {
				if e.kind == kind {
					// Remove the returned event so subsequent calls don't return it again
					r.events = append(r.events[:i], r.events[i+1:]...)
					r.mu.Unlock()
					return e
				}
			}
			r.mu.Unlock()
		case <-deadline:
			t.Fatalf("timeout waiting for %s", kind)
		}
	}
}

func TestDispatchConnectedEvent(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/x.db")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	sink := newRecSink()
	c.SetEventSink(sink)
	c.dispatch("Connected", `{"hello":"world"}`)
	e := sink.wait(t, "Connected", time.Second)
	if e.payload != `{"hello":"world"}` {
		t.Fatalf("payload = %q", e.payload)
	}
}
