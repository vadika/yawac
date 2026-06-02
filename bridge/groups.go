package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

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

// JParticipant represents a single member of a group, optionally
// carrying a per-row error code returned by UpdateGroupParticipants.
// When ErrorCode is non-zero and the server queued an invite-via-DM
// as fallback (privacy-block case), InviteCode + InviteExpiry are
// populated so the caller can render "invite sent, pending acceptance".
type JParticipant struct {
	JID          string `json:"jid"`
	IsAdmin      bool   `json:"is_admin"`
	IsSuper      bool   `json:"is_super_admin"`
	ErrorCode    int    `json:"error_code,omitempty"`
	InviteCode   string `json:"invite_code,omitempty"`
	InviteExpiry int64  `json:"invite_expiry,omitempty"`
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

// GetGroupInfo returns JSON of a single JGroup for `jid`, including
// fresh participants. Uses whatsmeow's GetGroupInfo (which queries the
// server). Returns ("", error) on failure.
//
// Retries once on ErrNotConnected — the inspector pane can be opened
// during the noise-handshake window right after launch / reconnect,
// where whatsmeow's socket isn't ready yet. A brief wait usually lets
// the second call succeed.
func (c *Client) GetGroupInfo(jidStr string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	g, err := c.wa.GetGroupInfo(context.Background(), jid)
	if errors.Is(err, whatsmeow.ErrNotConnected) {
		time.Sleep(750 * time.Millisecond)
		g, err = c.wa.GetGroupInfo(context.Background(), jid)
	}
	if err != nil {
		return "", fmt.Errorf("get group: %w", err)
	}
	out := JGroup{
		JID:               g.JID.String(),
		Name:              g.Name,
		Topic:             g.Topic,
		OwnerJID:          g.OwnerJID.String(),
		Created:           g.GroupCreated.Unix(),
		IsParent:          g.GroupParent.IsParent,
		LinkedParentJID:   g.GroupLinkedParent.LinkedParentJID.String(),
		IsDefaultSubGroup: g.GroupIsDefaultSub.IsDefaultSubGroup,
	}
	if !strings.HasSuffix(out.LinkedParentJID, "@g.us") {
		out.LinkedParentJID = ""
	}
	for _, p := range g.Participants {
		out.Participants = append(out.Participants, JParticipant{
			JID:     p.JID.String(),
			IsAdmin: p.IsAdmin,
			IsSuper: p.IsSuperAdmin,
		})
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

// CreateCommunity creates a new community parent group. The server
// auto-creates the default announcements sub-group, whose JID arrives
// via a JoinedGroup event shortly after. Returns the parent's JID.
// Surfaces the 25-char-name 406 from the server verbatim.
func (c *Client) CreateCommunity(name string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	info, err := c.wa.CreateGroup(context.Background(),
		whatsmeow.ReqCreateGroup{
			Name:        name,
			GroupParent: types.GroupParent{IsParent: true},
		})
	if err != nil {
		return "", fmt.Errorf("create community: %w", err)
	}
	return info.JID.String(), nil
}

// JSubGroup mirrors whatsmeow's types.GroupLinkTarget — a community
// parent's child entry. Carries name + JID + the default-sub flag, no
// participants (cheap directory listing).
type JSubGroup struct {
	JID               string `json:"jid"`
	Name              string `json:"name"`
	IsDefaultSubGroup bool   `json:"is_default_sub_group"`
}

// ListSubGroups returns every group linked under `parentJID` — both ones
// the user has joined and ones still available to join. Used by the
// ChatInfoView's parent inspector to render the full directory of a
// community.
func (c *Client) ListSubGroups(parentJID string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	parent, err := types.ParseJID(parentJID)
	if err != nil {
		return "", fmt.Errorf("parse parent: %w", err)
	}
	targets, err := c.wa.GetSubGroups(context.Background(), parent)
	if err != nil {
		return "", fmt.Errorf("get sub groups: %w", err)
	}
	out := make([]JSubGroup, 0, len(targets))
	for _, t := range targets {
		out = append(out, JSubGroup{
			JID:               t.JID.String(),
			Name:              t.GroupName.Name,
			IsDefaultSubGroup: t.GroupIsDefaultSub.IsDefaultSubGroup,
		})
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// JoinSubGroup is a best-effort community member join: fetches the
// sub-group's invite link (works for the user if the server treats
// community membership as inviter-equivalent) and joins via the
// returned code. Returns the joined JID on success. Surfaces the
// underlying error (forbidden / not-in-community) verbatim on failure
// so the UI can decide what to show.
func (c *Client) JoinSubGroup(subJID string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(subJID)
	if err != nil {
		return "", fmt.Errorf("parse sub: %w", err)
	}
	link, err := c.wa.GetGroupInviteLink(context.Background(), jid, false)
	if err != nil {
		return "", fmt.Errorf("get invite link: %w", err)
	}
	joined, err := c.wa.JoinGroupWithLink(context.Background(), link)
	if err != nil {
		return "", fmt.Errorf("join: %w", err)
	}
	return joined.String(), nil
}

// LeaveGroup removes the current user from the group `jidStr`.
func (c *Client) LeaveGroup(jidStr string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.LeaveGroup(context.Background(), jid)
}

// SetGroupName changes the displayed group name (WhatsApp "subject").
// The server fans the change out as an events.GroupInfo to every
// participant, including this client.
func (c *Client) SetGroupName(chatJID, name string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.SetGroupName(context.Background(), jid, name)
}

// SetGroupDescription changes the group description (WhatsApp "topic").
// Empty `description` clears it. Uses whatsmeow's SetGroupTopic, which
// auto-fetches the prior description ID and generates a new one — the
// id/prev versioning attrs WhatsApp requires for description updates.
// The simpler SetGroupDescription helper omits these and the server
// silently drops the IQ. Server fans the change out as an
// events.GroupInfo with a populated Topic field.
func (c *Client) SetGroupDescription(chatJID, description string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.SetGroupTopic(context.Background(), jid, "", "", description)
}

func participantChangeFromString(s string) (whatsmeow.ParticipantChange, error) {
	switch s {
	case "add":
		return whatsmeow.ParticipantChangeAdd, nil
	case "remove":
		return whatsmeow.ParticipantChangeRemove, nil
	case "promote":
		return whatsmeow.ParticipantChangePromote, nil
	case "demote":
		return whatsmeow.ParticipantChangeDemote, nil
	default:
		return "", fmt.Errorf("unknown participant action %q", s)
	}
}

// UpdateGroupParticipants applies one of "add" / "remove" / "promote" /
// "demote" to a batch of participant JIDs in `chatJID`. participantJIDsJSON
// is a JSON `[]string`. Returns a JSON `[]JParticipant` of the server's
// response (the changed rows only — caller merges into the local roster).
// Per-row failures (privacy block, invalid JID) surface via JParticipant
// ErrorCode + InviteCode + InviteExpiry rather than a method-level error.
func (c *Client) UpdateGroupParticipants(
	chatJID, action, participantJIDsJSON string,
) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse chat jid: %w", err)
	}
	act, err := participantChangeFromString(action)
	if err != nil {
		return "", err
	}
	var raw []string
	if err := json.Unmarshal([]byte(participantJIDsJSON), &raw); err != nil {
		return "", fmt.Errorf("parse jids: %w", err)
	}
	parsed := make([]types.JID, 0, len(raw))
	for _, s := range raw {
		j, err := types.ParseJID(s)
		if err != nil {
			return "", fmt.Errorf("parse %q: %w", s, err)
		}
		parsed = append(parsed, j)
	}
	resp, err := c.wa.UpdateGroupParticipants(context.Background(),
		chat, parsed, act)
	if err != nil {
		return "", fmt.Errorf("update participants: %w", err)
	}
	out := make([]JParticipant, 0, len(resp))
	for _, p := range resp {
		jp := JParticipant{
			JID:     p.JID.String(),
			IsAdmin: p.IsAdmin,
			IsSuper: p.IsSuperAdmin,
		}
		if p.Error != 0 {
			jp.ErrorCode = p.Error
			if p.AddRequest != nil {
				jp.InviteCode = p.AddRequest.Code
				jp.InviteExpiry = p.AddRequest.Expiration.Unix()
			}
		}
		out = append(out, jp)
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// SetGroupPhoto uploads `jpeg` bytes as the group's picture. Returns the
// new picture ID. Surfaces whatsmeow.ErrInvalidImageFormat verbatim when
// the bytes aren't a JPEG the server accepts.
func (c *Client) SetGroupPhoto(chatJID string, jpeg []byte) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	pictureID, err := c.wa.SetGroupPhoto(context.Background(), jid, jpeg)
	if err != nil {
		return "", fmt.Errorf("set photo: %w", err)
	}
	return pictureID, nil
}

// RemoveGroupPhoto clears the group's picture. Equivalent to SetGroupPhoto
// with nil bytes per whatsmeow's contract.
func (c *Client) RemoveGroupPhoto(chatJID string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	_, err = c.wa.SetGroupPhoto(context.Background(), jid, nil)
	if err != nil {
		return fmt.Errorf("remove photo: %w", err)
	}
	return nil
}

// GetGroupInviteLink returns the full `https://chat.whatsapp.com/<code>`.
// reset=true revokes the prior link before issuing the new one. Surfaces
// whatsmeow's ErrGroupInviteLinkUnauthorized / ErrGroupNotFound /
// ErrNotInGroup verbatim — the caller renders the localized message.
func (c *Client) GetGroupInviteLink(chatJID string, reset bool) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return "", fmt.Errorf("parse jid: %w", err)
	}
	link, err := c.wa.GetGroupInviteLink(context.Background(), jid, reset)
	if err != nil {
		return "", fmt.Errorf("get invite link: %w", err)
	}
	return link, nil
}

// stripInviteCodePrefix accepts any of:
//   https://chat.whatsapp.com/<code>, http://chat.whatsapp.com/<code>,
//   chat.whatsapp.com/<code>, https://wa.me/<code>, wa.me/<code>,
//   bare <code>.
// Returns the bare code. Defence-in-depth — the Swift parser already
// strips the prefix; we strip again here so the bridge can be called
// directly from tests or future surfaces without the cleanup.
func stripInviteCodePrefix(s string) string {
	s = strings.TrimPrefix(s, "https://")
	s = strings.TrimPrefix(s, "http://")
	s = strings.TrimPrefix(s, "chat.whatsapp.com/")
	s = strings.TrimPrefix(s, "wa.me/")
	return s
}

// GroupInfoFromLink resolves an invite link (URL or bare code) into a
// JGroup preview WITHOUT joining the group. Participants list is
// always empty in the response. Surfaces ErrInviteLinkRevoked /
// ErrInviteLinkInvalid verbatim.
func (c *Client) GroupInfoFromLink(code string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	info, err := c.wa.GetGroupInfoFromLink(
		context.Background(), stripInviteCodePrefix(code))
	if err != nil {
		return "", fmt.Errorf("group info from link: %w", err)
	}
	jg := JGroup{
		JID:               info.JID.String(),
		Name:              info.Name,
		Topic:             info.Topic,
		OwnerJID:          info.OwnerJID.String(),
		Created:           info.GroupCreated.Unix(),
		IsParent:          info.GroupParent.IsParent,
		LinkedParentJID:   info.GroupLinkedParent.LinkedParentJID.String(),
		IsDefaultSubGroup: info.GroupIsDefaultSub.IsDefaultSubGroup,
		Participants:      []JParticipant{}, // intentionally empty
	}
	if !strings.HasSuffix(jg.LinkedParentJID, "@g.us") {
		jg.LinkedParentJID = ""
	}
	b, _ := json.Marshal(jg)
	return string(b), nil
}

// JoinGroupViaLink joins via an invite link (URL or bare code).
// Returns the joined JID. Dual return semantics: a bare JID alone can
// mean the server queued a membership_approval_request — caller probes
// via GetGroupInfo to distinguish the joined case from "pending".
func (c *Client) JoinGroupViaLink(code string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	jid, err := c.wa.JoinGroupWithLink(
		context.Background(), stripInviteCodePrefix(code))
	if err != nil {
		return "", fmt.Errorf("join via link: %w", err)
	}
	return jid.String(), nil
}
