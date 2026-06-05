package bridge

// All JSON payloads exchanged with Swift are defined here for review.

type JMessage struct {
	ID               string            `json:"id"`
	ChatJID          string            `json:"chat_jid"`
	SenderJID        string            `json:"sender_jid"`
	SenderPushName   string            `json:"sender_push_name,omitempty"`
	FromMe           bool              `json:"from_me"`
	Timestamp        int64             `json:"timestamp"`
	Kind             string            `json:"kind"` // text, image, video, audio, document, sticker, location, location_live, contact, poll, system
	Text             string            `json:"text,omitempty"`
	Media            *JMedia           `json:"media,omitempty"`
	Poll             *JPoll            `json:"poll,omitempty"`
	Location         *JLocationPayload `json:"location,omitempty"`
	LocationSequence int64             `json:"location_sequence,omitempty"`
	Contact          *JContactPayload  `json:"contact,omitempty"`
	IsViewOnce       bool              `json:"is_view_once,omitempty"`
	Quoted           *JQuoted          `json:"quoted,omitempty"`
	IsForwarded      bool              `json:"is_forwarded,omitempty"`
}

type JLocationPayload struct {
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Name    string  `json:"name,omitempty"`
	Address string  `json:"address,omitempty"`
}

type JContactPayload struct {
	Vcard       string `json:"vcard"`
	DisplayName string `json:"display_name"`
}

type JQuoted struct {
	MessageID string `json:"message_id"`
	SenderJID string `json:"sender_jid"`
	FromMe    bool   `json:"from_me"`
	Kind      string `json:"kind"`
	Snippet   string `json:"snippet"`
}

type JMessageEdited struct {
	ChatJID   string `json:"chat_jid"`
	MessageID string `json:"message_id"`
	NewText   string `json:"new_text"`
	Timestamp int64  `json:"timestamp"`
}

type JMessageRevoked struct {
	ChatJID   string `json:"chat_jid"`
	MessageID string `json:"message_id"`
	RevokedBy string `json:"revoked_by"`
	Timestamp int64  `json:"timestamp"`
}

type JMessageLocallyDeleted struct {
	ChatJID   string `json:"chat_jid"`
	MessageID string `json:"message_id"`
	Timestamp int64  `json:"timestamp"`
}

type JMessageStarred struct {
	ChatJID   string `json:"chat_jid"`
	MessageID string `json:"message_id"`
	SenderJID string `json:"sender_jid"`
	FromMe    bool   `json:"from_me"`
	Starred   bool   `json:"starred"`
	Timestamp int64  `json:"timestamp"`
}

type JChatPinned struct {
	ChatJID   string `json:"chat_jid"`
	Pinned    bool   `json:"pinned"`
	Timestamp int64  `json:"timestamp"`
}

type JMessagePinned struct {
	ChatJID         string `json:"chat_jid"`
	TargetMessageID string `json:"target_message_id"`
	SenderJID       string `json:"sender_jid"`
	Pinned          bool   `json:"pinned"`
	Timestamp       int64  `json:"timestamp"`
}

type JPoll struct {
	Question        string        `json:"question"`
	Options         []JPollOption `json:"options"`
	SelectableCount int           `json:"selectable_count"` // 1 = single-choice, >1 = multi
}

type JPollOption struct {
	Name string `json:"name"`
	Hash string `json:"hash"` // hex-encoded SHA256(name) — opaque id used for vote tallies
}

type JPollVote struct {
	ChatJID       string   `json:"chat_jid"`
	PollMessageID string   `json:"poll_message_id"`
	VoterJID      string   `json:"voter_jid"`
	OptionHashes  []string `json:"option_hashes"`
	Timestamp     int64    `json:"timestamp"`
}

type JMedia struct {
	MimeType  string    `json:"mime_type"`
	Caption   string    `json:"caption,omitempty"`
	FileName  string    `json:"file_name,omitempty"` // documents only
	FilePath  string    `json:"file_path,omitempty"`
	Width     int       `json:"width,omitempty"`
	Height    int       `json:"height,omitempty"`
	Duration  int       `json:"duration,omitempty"` // seconds, audio/video
	SizeBytes int64     `json:"size_bytes,omitempty"`
	Ref       *MediaRef `json:"ref,omitempty"`
}

type JReceipt struct {
	ChatJID    string   `json:"chat_jid"`
	SenderJID  string   `json:"sender_jid"`
	MessageIDs []string `json:"message_ids"`
	Status     string   `json:"status"` // delivered, read, played
	Timestamp  int64    `json:"timestamp"`
}

type JSendResult struct {
	MessageID string `json:"message_id"`
	Timestamp int64  `json:"timestamp"`
}

// JSendPollResult is returned by SendPollCreation. Carries the canonical
// JPoll (built from the wire-form message) so the caller's local copy of
// the option hashes matches what peers will use for vote tallies.
type JSendPollResult struct {
	MessageID string `json:"message_id"`
	Timestamp int64  `json:"timestamp"`
	Poll      JPoll  `json:"poll"`
}

type JReaction struct {
	ChatJID         string `json:"chat_jid"`
	TargetMessageID string `json:"target_message_id"`
	TargetFromMe    bool   `json:"target_from_me"`
	SenderJID       string `json:"sender_jid"`
	Emoji           string `json:"emoji"`
	Timestamp       int64  `json:"timestamp"`
}

type JChatArchived struct {
	ChatJID   string `json:"chat_jid"`
	Archived  bool   `json:"archived"`
	Timestamp int64  `json:"timestamp"`
}

type JChatMuted struct {
	ChatJID      string `json:"chat_jid"`
	MutedUntilMs int64  `json:"muted_until_ms"`
	Timestamp    int64  `json:"timestamp"`
}

type JGroupInfoChanged struct {
	ChatJID           string `json:"chat_jid"`
	Name              string `json:"name"`        // empty = unchanged this event
	Description       string `json:"description"` // empty = unchanged this event
	LinkedParentJID   string `json:"linked_parent_jid,omitempty"`
	IsDefaultSubGroup bool   `json:"is_default_subgroup,omitempty"`
	Timestamp         int64  `json:"timestamp"`
}

// JJoinApprovalModeChanged carries a community/group's
// require-admin-approval-to-join toggle. Mode "request_required" → on=true.
// Anything else → on=false.
type JJoinApprovalModeChanged struct {
	ChatJID   string `json:"chat_jid"`
	On        bool   `json:"on"`
	ActorJID  string `json:"actor_jid,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

// JGroupAnnounceChanged carries a group's announce-mode toggle (admin-only
// posting). On=true means only admins can send messages.
type JGroupAnnounceChanged struct {
	ChatJID   string `json:"chat_jid"`
	On        bool   `json:"on"`
	ActorJID  string `json:"actor_jid,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

// JGroupLockedChanged carries a group's locked-mode toggle (admin-only
// edit-info). On=true means only admins can edit group info (name,
// description, icon).
type JGroupLockedChanged struct {
	ChatJID   string `json:"chat_jid"`
	On        bool   `json:"on"`
	ActorJID  string `json:"actor_jid,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

// JEphemeralTimerChanged carries a disappearing-messages timer change for
// a chat. Seconds == 0 means "off" (timer cleared). Fan-out source is
// either a group GroupInfo with non-nil Ephemeral, or a 1:1 inbound
// ProtocolMessage of type EPHEMERAL_SETTING (the carrier message that
// otherwise would render as a noise bubble).
type JEphemeralTimerChanged struct {
	ChatJID   string `json:"chat_jid"`
	Seconds   int32  `json:"seconds"`
	ActorJID  string `json:"actor_jid,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

// JGroupParticipantsChanged carries a single action verb (add / remove /
// promote / demote) and the affected participant JIDs. A single
// whatsmeow events.GroupInfo can carry more than one — the dispatcher
// emits one of these per non-empty slice.
type JGroupParticipantsChanged struct {
	ChatJID   string   `json:"chat_jid"`
	Action    string   `json:"action"`
	ActorJID  string   `json:"actor_jid,omitempty"`
	JIDs      []string `json:"jids"`
	Timestamp int64    `json:"timestamp"`
}

type JChatDeleted struct {
	ChatJID   string `json:"chat_jid"`
	Timestamp int64  `json:"timestamp"`
}

type JContactUpdated struct {
	JID       string `json:"jid"`
	FullName  string `json:"full_name"`
	FirstName string `json:"first_name"`
}

type JBlockChange struct {
	JID    string `json:"jid"`
	Action string `json:"action"`
}

type JBlocklistChanged struct {
	Action  string         `json:"action"`
	Changes []JBlockChange `json:"changes"`
}
