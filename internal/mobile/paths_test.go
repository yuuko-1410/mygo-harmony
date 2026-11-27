package mobile

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/egoist/mygo/internal/mobile/wire"
)

// TestSetHomeDirs checks that the host's directories become where the app
// keeps its things, and that the system's own are kept where it has them.
func TestSetHomeDirs(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("XDG_CACHE_HOME", "")
	setHomeDirs(wire.AppInfoReply{FilesDir: dir, CacheDir: filepath.Join(dir, "cache")})
	if got := os.Getenv("XDG_CONFIG_HOME"); got != dir {
		t.Fatalf("XDG_CONFIG_HOME = %q, want the app's files directory", got)
	}
	if got := os.Getenv("XDG_CACHE_HOME"); got != filepath.Join(dir, "cache") {
		t.Fatalf("XDG_CACHE_HOME = %q, want the app's cache directory", got)
	}
	if d, err := os.UserConfigDir(); err != nil || d != dir {
		t.Fatalf("os.UserConfigDir() = %q, %v, want the app's files directory", d, err)
	}
}

// TestSetHomeDirsKeepsTheSystems checks that a system that does set them is
// left alope.
func TestSetHomeDirsKeepsTheSystems(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/system/config")
	setHomeDirs(wire.AppInfoReply{FilesDir: t.TempDir()})
	if got := os.Getenv("XDG_CONFIG_HOME"); got != "/system/config" {
		t.Fatalf("XDG_CONFIG_HOME = %q, wanted the system's", got)
	}
}
