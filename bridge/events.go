package bridge

import (
	"encoding/json"
	"fmt"
	"os"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// SetEventSink installs the Swift-side callback target.
// Replaces any prior sink.
func (c *Client) SetEventSink(s EventSink) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sink = s
}

// dispatch is the single point where Go events fan out to the Swift sink.
// Always async to keep the whatsmeow event goroutine non-blocking.
func (c *Client) dispatch(kind, payload string) {
	c.mu.Lock()
	sink := c.sink
	c.mu.Unlock()
	if sink == nil {
		return
	}
	go sink.OnEvent(kind, payload)
}

// handleWAEvent is registered with whatsmeow.Client.AddEventHandler.
func (c *Client) handleWAEvent(evt any) {
	switch v := evt.(type) {
	case *events.Connected:
		c.dispatch("Connected", "{}")
	case *events.Disconnected:
		c.dispatch("Disconnected", "{}")
	case *events.LoggedOut:
		b, _ := json.Marshal(map[string]any{"reason": v.Reason.String()})
		c.dispatch("LoggedOut", string(b))
	case *events.QR:
		b, _ := json.Marshal(map[string]any{"codes": v.Codes})
		c.dispatch("QR", string(b))
	case *events.PairSuccess:
		b, _ := json.Marshal(map[string]any{
			"id":       v.ID.String(),
			"platform": v.Platform,
		})
		c.dispatch("PairSuccess", string(b))
	case *events.OfflineSyncPreview:
		b, _ := json.Marshal(map[string]any{
			"total":         v.Total,
			"appdata":       v.AppDataChanges,
			"messages":      v.Messages,
			"notifications": v.Notifications,
			"receipts":      v.Receipts,
		})
		c.dispatch("OfflineSyncPreview", string(b))
	case *events.OfflineSyncCompleted:
		b, _ := json.Marshal(map[string]any{
			"server_count": v.Count,
		})
		c.dispatch("OfflineSyncCompleted", string(b))
	case *events.Message:
		// F118: message recovered from the primary phone via
		// placeholder-resend (RequestMessageResend or automatic
		// rerequest). Rare enough to log every occurrence.
		if v.UnavailableRequestID != "" {
			fmt.Fprintf(os.Stderr,
				"[yawac/resent] id=%s chat=%s sender=%s\n",
				v.Info.ID, v.Info.Chat, v.Info.Sender)
		}
		c.dispatchMessage(v)
	case *events.Receipt:
		c.dispatchReceipt(v)
	case *events.UndecryptableMessage:
		// Do NOT dispatch to Swift — no UI for undecryptable
		// messages. whatsmeow sends a retry receipt to the sender
		// and (F118) requests a resend from the primary phone; the
		// recovered copy arrives as a normal Message event. Log so
		// losses are greppable instead of invisible.
		fmt.Fprintf(os.Stderr,
			"[yawac/undecrypt] id=%s chat=%s sender=%s unavailable=%v mode=%s\n",
			v.Info.ID, v.Info.Chat, v.Info.Sender, v.IsUnavailable, v.DecryptFailMode)
	case *events.Presence:
		c.dispatchPresence(v)
	case *events.ChatPresence:
		c.dispatchChatPresence(v)
	case *events.HistorySync:
		c.dispatchHistory(v)
	case *events.MediaRetry:
		c.handleMediaRetry(v)
	case *events.DeleteForMe:
		c.dispatchDeleteForMe(v)
	case *events.Star:
		c.dispatchStar(v)
	case *events.Pin:
		c.dispatchPin(v)
	case *events.Archive:
		c.dispatchArchive(v)
	case *events.Mute:
		c.dispatchMute(v)
	case *events.GroupInfo:
		c.dispatchGroupInfo(v)
		c.dispatchGroupParticipants(v)
	case *events.DeleteChat:
		c.dispatchDeleteChat(v)
	case *events.Contact:
		c.dispatchContact(v)
	case *events.Blocklist:
		c.dispatchBlocklist(v)
	case *events.IdentityChange:
		// F35: surface as an inline system message so the user sees
		// "Encryption key with X changed" in the chat. Server-pushed
		// notifications only (Implicit=true means whatsmeow triggered
		// it locally on an untrusted-identity error; less interesting
		// to display).
		if !v.Implicit {
			c.dispatchIdentityChange(v)
		}
	}
}

// dispatchIdentityChange emits a synthetic Message with kind="system"
// so the regular chat ingest path persists + renders it inline. The
// peer JID is left in the text un-resolved; the Swift side
// mentionResolver kicks in at render time only for @-mention rewrites,
// not arbitrary inline text, so we ship a stable phrasing.
// F35.
func (c *Client) dispatchIdentityChange(evt *events.IdentityChange) {
	chatJID := evt.JID.String()
	senderJID := evt.JID.String()
	ts := evt.Timestamp.Unix()
	id := fmt.Sprintf("yawac-identity-%s-%d", evt.JID.String(), ts)
	text := fmt.Sprintf("Encryption key with %s changed.", evt.JID.User)
	b, _ := json.Marshal(JMessage{
		ID:        id,
		ChatJID:   chatJID,
		SenderJID: senderJID,
		FromMe:    false,
		Timestamp: ts,
		Kind:      "system",
		Text:      text,
	})
	c.dispatch("Message", string(b))
}

// dispatchPin surfaces app-state pin/unpin events (a chat pinned
// or unpinned from another companion device).
func (c *Client) dispatchPin(evt *events.Pin) {
	pinned := false
	if a := evt.Action; a != nil {
		pinned = a.GetPinned()
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/pin] dispatch jid=%s pinned=%v fullSync=%v\n",
		evt.JID.String(), pinned, evt.FromFullSync)
	b, _ := json.Marshal(JChatPinned{
		ChatJID:   evt.JID.String(),
		Pinned:    pinned,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("ChatPinned", string(b))
}

// dispatchStar surfaces app-state star/unstar events (a message
// (un)starred from another companion device) so the local row's
// starredAt can be reconciled without a round-trip.
func (c *Client) dispatchStar(evt *events.Star) {
	starred := false
	if a := evt.Action; a != nil {
		starred = a.GetStarred()
	}
	b, _ := json.Marshal(JMessageStarred{
		ChatJID:   evt.ChatJID.String(),
		MessageID: evt.MessageID,
		SenderJID: evt.SenderJID.String(),
		FromMe:    evt.IsFromMe,
		Starred:   starred,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("MessageStarred", string(b))
}

// dispatchDeleteForMe surfaces app-state "delete-for-me" events
// (a message hidden on another companion device, not revoked
// globally) to the Swift side as MessageLocallyDeleted.
func (c *Client) dispatchDeleteForMe(evt *events.DeleteForMe) {
	b, _ := json.Marshal(JMessageLocallyDeleted{
		ChatJID:   evt.ChatJID.String(),
		MessageID: evt.MessageID,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("MessageLocallyDeleted", string(b))
}

func (c *Client) dispatchReceipt(evt *events.Receipt) {
	status := "delivered"
	switch evt.Type {
	case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
		status = "read"
	case types.ReceiptTypePlayed:
		status = "played"
	case types.ReceiptTypeDelivered:
		status = "delivered"
	}
	b, _ := json.Marshal(JReceipt{
		ChatJID:    evt.Chat.String(),
		SenderJID:  evt.Sender.String(),
		MessageIDs: evt.MessageIDs,
		Status:     status,
		Timestamp:  evt.Timestamp.Unix(),
	})
	c.dispatch("Receipt", string(b))
}

func (c *Client) dispatchPresence(evt *events.Presence) {
	b, _ := json.Marshal(map[string]any{
		"from":        evt.From.String(),
		"unavailable": evt.Unavailable,
		"last_seen":   evt.LastSeen.Unix(),
	})
	c.dispatch("Presence", string(b))
}

func (c *Client) dispatchChatPresence(evt *events.ChatPresence) {
	b, _ := json.Marshal(map[string]any{
		"chat":   evt.MessageSource.Chat.String(),
		"sender": evt.MessageSource.Sender.String(),
		"state":  string(evt.State), // composing, paused
		"media":  string(evt.Media), // text, audio
	})
	c.dispatch("ChatPresence", string(b))
}

func (c *Client) dispatchHistory(evt *events.HistorySync) {
	c.applyHistorySync(evt)
	convs := evt.Data.GetConversations()
	// Count messages inside this chunk so the Swift Settings panel can
	// show a running "X messages so far" counter during user-initiated
	// full sync (F28). Same loop the F-instr trace used; cost is one
	// extra range per chunk, negligible.
	var chunkMessages int
	for _, conv := range convs {
		chunkMessages += len(conv.GetMessages())
	}
	payload := map[string]any{
		"sync_type":      evt.Data.GetSyncType().String(),
		"conversations":  len(convs),
		"progress":       int(evt.Data.GetProgress()),
		"chunk_order":    int(evt.Data.GetChunkOrder()),
		"chunk_messages": chunkMessages,
	}
	b, _ := json.Marshal(payload)
	c.dispatch("HistorySync", string(b))
}

// dispatchArchive surfaces app-state archive/unarchive events (a chat
// (un)archived from the phone or another companion device).
func (c *Client) dispatchArchive(evt *events.Archive) {
	archived := false
	if a := evt.Action; a != nil {
		archived = a.GetArchived()
	}
	b, _ := json.Marshal(JChatArchived{
		ChatJID:   evt.JID.String(),
		Archived:  archived,
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("ChatArchived", string(b))
}

// dispatchMute surfaces app-state mute/unmute events (a chat
// (un)muted from the phone or another companion device). MutedUntil
// is normalized to Unix milliseconds; 0 means the event was an
// unmute.
func (c *Client) dispatchMute(evt *events.Mute) {
	muted := false
	var untilMs int64
	if a := evt.Action; a != nil {
		muted = a.GetMuted()
		if mu := a.GetMuteEndTimestamp(); mu != 0 {
			untilMs = mu
		}
	}
	if !muted {
		untilMs = 0
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/mute] dispatch jid=%s muted=%v until_ms=%d fullSync=%v\n",
		evt.JID.String(), muted, untilMs, evt.FromFullSync)
	b, _ := json.Marshal(JChatMuted{
		ChatJID:      evt.JID.String(),
		MutedUntilMs: untilMs,
		Timestamp:    evt.Timestamp.Unix(),
	})
	c.dispatch("ChatMuted", string(b))
}

// dispatchGroupInfo surfaces app-level group metadata changes
// (name, description, linked-parent / default-sub flags) and
// additionally fans out a JoinApprovalModeChanged event when the
// membership-approval gate flipped. Other GroupInfo fields (locked,
// announce, ephemeral, participant changes) are ignored here — they
// belong on separate handlers. When this event carried no
// metadata-changed field at all (no name, description, link, default-sub
// flag), we skip the GroupInfoChanged dispatch but still emit the
// approval-mode event if MembershipApprovalMode was set.
func (c *Client) dispatchGroupInfo(evt *events.GroupInfo) {
	var name, description string
	if evt.Name != nil {
		name = evt.Name.Name
	}
	if evt.Topic != nil {
		description = evt.Topic.Topic
	}

	// Pull linked-parent / default-sub from the link change, if any. A
	// GroupInfo for a freshly-linked sub-group carries Link with
	// Type==parent_group; the linked target is the parent.
	var linkedParent string
	var isDefaultSub bool
	if evt.Link != nil && evt.Link.Type == types.GroupLinkChangeTypeParent {
		linkedParent = normalizeGroupJID(evt.Link.Group.JID.String())
		isDefaultSub = evt.Link.Group.IsDefaultSubGroup
	}

	// Emit GroupInfoChanged when any of the metadata fields carried a value.
	if name != "" || description != "" || linkedParent != "" || isDefaultSub {
		fmt.Fprintf(os.Stderr,
			"[yawac/groupInfo] dispatch jid=%s name=%q desc_len=%d parent=%q defSub=%v\n",
			evt.JID.String(), name, len(description), linkedParent, isDefaultSub)
		b, _ := json.Marshal(JGroupInfoChanged{
			ChatJID:           evt.JID.String(),
			Name:              name,
			Description:       description,
			LinkedParentJID:   linkedParent,
			IsDefaultSubGroup: isDefaultSub,
			Timestamp:         evt.Timestamp.Unix(),
		})
		c.dispatch("GroupInfoChanged", string(b))
	}

	// Additionally surface a join-approval-mode toggle. whatsmeow exposes
	// this as a bool IsJoinApprovalRequired; map true → on=true.
	if evt.MembershipApprovalMode != nil {
		actor := ""
		if evt.Sender != nil {
			actor = evt.Sender.String()
		}
		b, _ := json.Marshal(JJoinApprovalModeChanged{
			ChatJID:   evt.JID.String(),
			On:        evt.MembershipApprovalMode.IsJoinApprovalRequired,
			ActorJID:  actor,
			Timestamp: evt.Timestamp.Unix(),
		})
		c.dispatch("JoinApprovalModeChanged", string(b))
	}

	// Announce-mode toggle (admin-only posting). types.GroupAnnounce
	// carries IsAnnounce; forward as on=true/false.
	if evt.Announce != nil {
		actor := ""
		if evt.Sender != nil {
			actor = evt.Sender.String()
		}
		b, _ := json.Marshal(JGroupAnnounceChanged{
			ChatJID:   evt.JID.String(),
			On:        evt.Announce.IsAnnounce,
			ActorJID:  actor,
			Timestamp: evt.Timestamp.Unix(),
		})
		c.dispatch("GroupAnnounceChanged", string(b))
	}

	// Locked-mode toggle (admin-only edit-info). types.GroupLocked
	// carries IsLocked; forward as on=true/false.
	if evt.Locked != nil {
		actor := ""
		if evt.Sender != nil {
			actor = evt.Sender.String()
		}
		b, _ := json.Marshal(JGroupLockedChanged{
			ChatJID:   evt.JID.String(),
			On:        evt.Locked.IsLocked,
			ActorJID:  actor,
			Timestamp: evt.Timestamp.Unix(),
		})
		c.dispatch("GroupLockedChanged", string(b))
	}

	// Member-add-mode toggle (who can add new participants). whatsmeow's
	// events.GroupInfo does NOT promote this to a typed field — the
	// upstream parser routes "member_add_mode" change nodes into
	// UnknownChanges. Scan for them and emit on match. Node content is
	// the raw mode string ("admin_add" or "all_member_add").
	if mode, ok := extractMemberAddMode(evt.UnknownChanges); ok {
		actor := ""
		if evt.Sender != nil {
			actor = evt.Sender.String()
		}
		b, _ := json.Marshal(JGroupMemberAddModeChanged{
			ChatJID:          evt.JID.String(),
			AllMembersCanAdd: mode == types.GroupMemberAddModeAllMember,
			ActorJID:         actor,
			Timestamp:        evt.Timestamp.Unix(),
		})
		c.dispatch("GroupMemberAddModeChanged", string(b))
	}

	// Disappearing-messages timer change. types.GroupEphemeral carries
	// IsEphemeral + DisappearingTimer; we forward the timer regardless of
	// IsEphemeral (timer==0 already encodes "off" on the Swift side).
	if evt.Ephemeral != nil {
		actor := ""
		if evt.Sender != nil {
			actor = evt.Sender.String()
		}
		b, _ := json.Marshal(JEphemeralTimerChanged{
			ChatJID:   evt.JID.String(),
			Seconds:   int32(evt.Ephemeral.DisappearingTimer),
			ActorJID:  actor,
			Timestamp: evt.Timestamp.Unix(),
		})
		c.dispatch("EphemeralTimerChanged", string(b))
	}
}

// extractMemberAddMode walks the GroupInfo's UnknownChanges looking for
// the "member_add_mode" notification node — whatsmeow's parseGroupChange
// doesn't promote this to a typed field, so we pluck it from the raw
// node list. Node content is the mode string ("admin_add" /
// "all_member_add"). Returns (mode, true) on match.
func extractMemberAddMode(unknown []*waBinary.Node) (types.GroupMemberAddMode, bool) {
	for _, n := range unknown {
		if n == nil || n.Tag != "member_add_mode" {
			continue
		}
		switch v := n.Content.(type) {
		case []byte:
			return types.GroupMemberAddMode(v), true
		case string:
			return types.GroupMemberAddMode(v), true
		}
	}
	return "", false
}

// normalizeGroupJID treats anything that isn't a `@g.us` JID as the
// empty string. Mirrors the logic in ListGroups for the LinkedParentJID
// promotion — whatsmeow returns the zero JID as a bare default server
// suffix when no parent is set.
func normalizeGroupJID(jid string) string {
	if jid != "" && len(jid) >= 5 && jid[len(jid)-5:] != "@g.us" {
		return ""
	}
	return jid
}

// dispatchDeleteChat surfaces app-state delete-chat events (a conversation
// cleared on the phone or another companion device).
func (c *Client) dispatchDeleteChat(evt *events.DeleteChat) {
	b, _ := json.Marshal(JChatDeleted{
		ChatJID:   evt.JID.String(),
		Timestamp: evt.Timestamp.Unix(),
	})
	c.dispatch("ChatDeleted", string(b))
}

// dispatchContact surfaces app-state contact-name changes so a name saved
// on the phone shows up locally.
func (c *Client) dispatchContact(evt *events.Contact) {
	full, first := "", ""
	if a := evt.Action; a != nil {
		full = a.GetFullName()
		first = a.GetFirstName()
	}
	b, _ := json.Marshal(JContactUpdated{
		JID:       evt.JID.String(),
		FullName:  full,
		FirstName: first,
	})
	c.dispatch("ContactUpdated", string(b))
}

// dispatchBlocklist surfaces blocklist changes. When Action == "modify"
// the Changes list is empty and the Swift side re-fetches the whole list.
func (c *Client) dispatchBlocklist(evt *events.Blocklist) {
	changes := make([]JBlockChange, 0, len(evt.Changes))
	for _, ch := range evt.Changes {
		changes = append(changes, JBlockChange{
			JID:    ch.JID.String(),
			Action: string(ch.Action),
		})
	}
	b, _ := json.Marshal(JBlocklistChanged{
		Action:  string(evt.Action),
		Changes: changes,
	})
	c.dispatch("BlocklistChanged", string(b))
}

// dispatchGroupParticipants splits a single events.GroupInfo into up to
// four GroupParticipantsChanged events, one per non-empty Join / Leave
// / Promote / Demote slice. Skips emit when every slice is empty. Sender
// JID populates ActorJID; missing sender → "".
func (c *Client) dispatchGroupParticipants(evt *events.GroupInfo) {
	fan := []struct {
		action string
		jids   []types.JID
	}{
		{"add", evt.Join}, {"remove", evt.Leave},
		{"promote", evt.Promote}, {"demote", evt.Demote},
	}
	actor := ""
	if evt.Sender != nil {
		actor = evt.Sender.String()
	}
	for _, f := range fan {
		if len(f.jids) == 0 {
			continue
		}
		out := make([]string, len(f.jids))
		for i, j := range f.jids {
			out[i] = j.String()
		}
		b, _ := json.Marshal(JGroupParticipantsChanged{
			ChatJID:   evt.JID.String(),
			Action:    f.action,
			ActorJID:  actor,
			JIDs:      out,
			Timestamp: evt.Timestamp.Unix(),
		})
		c.dispatch("GroupParticipantsChanged", string(b))
	}
}
