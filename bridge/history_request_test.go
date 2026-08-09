package bridge

import (
	"encoding/hex"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"google.golang.org/protobuf/proto"
)

func TestRequestOlderHistoryBadChat(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/rh.db")
	defer c.Close()
	err := c.RequestOlderHistory("abc:def@x", "ID", "1@s.whatsapp.net", false, 0, 50)
	if err == nil || !strings.Contains(err.Error(), "parse chat") {
		t.Fatalf("got %v", err)
	}
}

func TestRequestFullHistorySyncUnpaired(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/hr.db")
	defer c.Close()
	err := c.RequestFullHistorySync(
		"1@s.whatsapp.net", "MSG1", false, 1700000000, 100000)
	if err == nil {
		t.Fatal("expected error on unpaired client")
	}
}

func TestRequestFullHistorySyncBadJID(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/hr2.db")
	defer c.Close()
	err := c.RequestFullHistorySync(
		"not a jid", "MSG1", false, 1700000000, 100000)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestRequestFullHistorySyncSignatureCompiles(t *testing.T) {
	var _ func(*Client) func(string, string, bool, int64, int32) error = func(c *Client) func(string, string, bool, int64, int32) error {
		return c.RequestFullHistorySync
	}
}

func TestBuildFullHistorySyncRequestIncludesDeviceConfig(t *testing.T) {
	originalProps := store.DeviceProps
	t.Cleanup(func() { store.DeviceProps = originalProps })
	store.DeviceProps = &waCompanionReg.DeviceProps{
		HistorySyncConfig: &waCompanionReg.DeviceProps_HistorySyncConfig{
			FullSyncDaysLimit:     proto.Uint32(3650),
			OnDemandReady:         proto.Bool(true),
			CompleteOnDemandReady: proto.Bool(true),
		},
	}

	from := time.Unix(1_785_960_000, 0)
	request := buildFullHistorySyncRequest(from, 30).
		GetProtocolMessage().GetPeerDataOperationRequestMessage()
	if request.GetPeerDataOperationRequestType() != waE2E.PeerDataOperationRequestType_FULL_HISTORY_SYNC_ON_DEMAND {
		t.Fatalf("unexpected request type: %s", request.GetPeerDataOperationRequestType())
	}
	fullRequest := request.GetFullHistorySyncOnDemandRequest()
	if !proto.Equal(fullRequest.GetHistorySyncConfig(), store.DeviceProps.HistorySyncConfig) {
		t.Fatalf("history sync config missing from request: %v", fullRequest.GetHistorySyncConfig())
	}
	if fullRequest.HistorySyncConfig == store.DeviceProps.HistorySyncConfig {
		t.Fatal("request must clone the global history sync config")
	}
	config := fullRequest.GetFullHistorySyncOnDemandConfig()
	if config.GetHistoryFromTimestamp() != uint64(from.Unix()) || config.GetHistoryDurationDays() != 30 {
		t.Fatalf("unexpected range: from=%d days=%d", config.GetHistoryFromTimestamp(), config.GetHistoryDurationDays())
	}
	requestID := fullRequest.GetRequestMetadata().GetRequestID()
	if decoded, err := hex.DecodeString(requestID); err != nil || len(decoded) != 16 {
		t.Fatalf("invalid request ID %q: decoded=%d err=%v", requestID, len(decoded), err)
	}
}
