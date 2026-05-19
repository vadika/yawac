package bridge

import (
	"strings"
	"testing"
)

func TestVersion(t *testing.T) {
	v := Version()
	if !strings.Contains(v, "yawac-bridge") {
		t.Fatalf("Version() = %q, want substring 'yawac-bridge'", v)
	}
}
