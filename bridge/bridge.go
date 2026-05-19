// Package bridge exposes a gomobile-friendly facade over whatsmeow.
//
// All exported symbols are subject to gomobile's binding constraints:
//   - parameter and return types must be: basic types (string, int, int64,
//     bool, []byte), gomobile-bound struct pointers, or interface types
//     defined in this package.
//   - complex payloads cross the boundary as JSON strings (see jsonmodels.go).
package bridge

const bridgeVersion = "yawac-bridge/0.1.0"

// Version returns the bridge package's version string.
func Version() string {
	return bridgeVersion
}
