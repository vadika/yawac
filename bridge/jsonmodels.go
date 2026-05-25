package bridge

// All JSON payloads exchanged with Swift are defined here for review.

type JMessage struct {
	ID             string   `json:"id"`
	ChatJID        string   `json:"chat_jid"`
	SenderJID      string   `json:"sender_jid"`
	SenderPushName string   `json:"sender_push_name,omitempty"`
	FromMe         bool     `json:"from_me"`
	Timestamp      int64    `json:"timestamp"`
	Kind           string   `json:"kind"` // text, image, video, audio, document, sticker, location, poll, system
	Text           string   `json:"text,omitempty"`
	Media          *JMedia  `json:"media,omitempty"`
	Poll           *JPoll   `json:"poll,omitempty"`
	Quoted         *JQuoted `json:"quoted,omitempty"`
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

type JReaction struct {
	ChatJID         string `json:"chat_jid"`
	TargetMessageID string `json:"target_message_id"`
	TargetFromMe    bool   `json:"target_from_me"`
	SenderJID       string `json:"sender_jid"`
	Emoji           string `json:"emoji"`
	Timestamp       int64  `json:"timestamp"`
}
