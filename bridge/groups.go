package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

// JGroup is the JSON-friendly view of a WhatsApp group.
type JGroup struct {
	JID               string         `json:"jid"`
	Name              string         `json:"name"`
	Topic             string         `json:"topic"`
	OwnerJID          string         `json:"owner_jid"`
	Created           int64          `json:"created"`
	IsParent          bool           `json:"is_parent,omitempty"`
	LinkedParentJID   string         `json:"linked_parent_jid,omitempty"`
	IsDefaultSubGroup bool           `json:"is_default_sub_group,omitempty"`
	Participants      []JParticipant `json:"participants"`
}

// JParticipant represents a single member of a group.
type JParticipant struct {
	JID     string `json:"jid"`
	IsAdmin bool   `json:"is_admin"`
	IsSuper bool   `json:"is_super_admin"`
}

// ListGroups returns the JSON-encoded array of groups the user has joined.
// On an unpaired client, whatsmeow returns an error; we surface it so the
// caller can decide (the test treats this as Skip).
func (c *Client) ListGroups() (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	gs, err := c.wa.GetJoinedGroups(context.Background())
	if err != nil {
		return "", fmt.Errorf("get groups: %w", err)
	}
	out := make([]JGroup, 0, len(gs))
	for _, g := range gs {
		// LinkedParentJID may come back as the zero JID (rendered as the
		// bare default server, e.g. "@s.whatsapp.net") when whatsmeow has
		// no parent set. Treat anything that isn't a `@g.us` JID as none.
		linked := g.GroupLinkedParent.LinkedParentJID.String()
		if linked != "" && len(linked) >= 5 && linked[len(linked)-5:] != "@g.us" {
			linked = ""
		}
		jg := JGroup{
			JID:               g.JID.String(),
			Name:              g.Name,  // promoted from embedded GroupName
			Topic:             g.Topic, // promoted from embedded GroupTopic
			OwnerJID:          g.OwnerJID.String(),
			Created:           g.GroupCreated.Unix(),
			IsParent:          g.GroupParent.IsParent,
			LinkedParentJID:   linked,
			IsDefaultSubGroup: g.GroupIsDefaultSub.IsDefaultSubGroup,
		}
		jg.Participants = make([]JParticipant, 0, len(g.Participants))
		for _, p := range g.Participants {
			jg.Participants = append(jg.Participants, JParticipant{
				JID:     p.JID.String(),
				IsAdmin: p.IsAdmin,
				IsSuper: p.IsSuperAdmin,
			})
		}
		out = append(out, jg)
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// CreateGroup creates a new group with the given display name and
// participant JIDs. participantJIDs must be a JSON array of strings.
// Returns the new group's JID string.
func (c *Client) CreateGroup(name string, participantJIDs string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	var jids []string
	if err := json.Unmarshal([]byte(participantJIDs), &jids); err != nil {
		return "", fmt.Errorf("parse jids: %w", err)
	}
	parsed := make([]types.JID, 0, len(jids))
	for _, s := range jids {
		j, err := types.ParseJID(s)
		if err != nil {
			return "", fmt.Errorf("parse %q: %w", s, err)
		}
		parsed = append(parsed, j)
	}
	info, err := c.wa.CreateGroup(context.Background(),
		whatsmeow.ReqCreateGroup{Name: name, Participants: parsed})
	if err != nil {
		return "", fmt.Errorf("create: %w", err)
	}
	return info.JID.String(), nil
}
