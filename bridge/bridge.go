// Package bridge exposes a gomobile-friendly facade over whatsmeow.
//
// All exported symbols are subject to gomobile's binding constraints:
//   - parameter and return types must be: basic types (string, int, int64,
//     bool, []byte), gomobile-bound struct pointers, or interface types
//     defined in this package.
//   - complex payloads cross the boundary as JSON strings (see jsonmodels.go).
package bridge

// EventSink is implemented on the Swift side and receives bridge events as
// JSON-encoded payloads. The type field discriminates the JSON shape.
type EventSink interface {
	OnEvent(eventType string, jsonPayload string)
}
