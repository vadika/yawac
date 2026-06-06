package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow/types"
)

// JLinkedDevice is the JSON shape returned by ListLinkedDevices.
// Mirrored on the Swift side as BridgeLinkedDevice.
type JLinkedDevice struct {
	JID      string `json:"jid"`       // full device JID (`<user>:<device>@...`)
	DeviceID int    `json:"device_id"` // numeric suffix (0 = the phone)
	IsSelf   bool   `json:"is_self"`   // true for the device this client is paired as
	IsPhone  bool   `json:"is_phone"`  // device_id == 0
}

// ListLinkedDevices returns every device paired to the paired
// account, including the phone (DeviceID = 0) and all companions.
// Wraps whatsmeow's GetUserDevices against the bare own JID.
func (c *Client) ListLinkedDevices() (string, error) {
	if c.wa == nil || c.wa.Store == nil || c.wa.Store.ID == nil {
		return "", errors.New("not paired")
	}
	own := c.wa.Store.ID.ToNonAD()
	jids, err := c.wa.GetUserDevices(context.Background(), []types.JID{own})
	if err != nil {
		return "", fmt.Errorf("list linked devices: %w", err)
	}
	selfID := int(c.wa.Store.ID.Device)
	out := make([]JLinkedDevice, 0, len(jids))
	for _, j := range jids {
		out = append(out, JLinkedDevice{
			JID:      j.String(),
			DeviceID: int(j.Device),
			IsSelf:   int(j.Device) == selfID,
			IsPhone:  j.Device == 0,
		})
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
