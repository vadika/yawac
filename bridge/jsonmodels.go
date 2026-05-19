package bridge

// All JSON payloads exchanged with Swift are defined here for review.

type JMessage struct {
	ID        string  `json:"id"`
	ChatJID   string  `json:"chat_jid"`
	SenderJID string  `json:"sender_jid"`
	FromMe    bool    `json:"from_me"`
	Timestamp int64   `json:"timestamp"`
	Kind      string  `json:"kind"` // text, image, video, audio, document, sticker, location, system
	Text      string  `json:"text,omitempty"`
	Media     *JMedia `json:"media,omitempty"`
	QuotedID  string  `json:"quoted_id,omitempty"`
}

type JMedia struct {
	MimeType  string `json:"mime_type"`
	Caption   string `json:"caption,omitempty"`
	FilePath  string `json:"file_path,omitempty"`
	Width     int    `json:"width,omitempty"`
	Height    int    `json:"height,omitempty"`
	Duration  int    `json:"duration,omitempty"` // seconds, audio/video
	SizeBytes int64  `json:"size_bytes,omitempty"`
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
