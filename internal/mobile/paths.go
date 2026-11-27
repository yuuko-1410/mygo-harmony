package mobile

import (
	"os"

	"github.com/egoist/mygo/internal/mobile/wire"
)

// setHomeDirs has the app keep what it keeps where the host says apps do.
//
// A phone's app has no home directory of the system's: os.UserConfigDir and
// os.UserCacheDir find none there, and what the app saves — its settings,
// its login, where playback was left — is written nowhere, silently, on
// every launch. The directories the host reports stand in.
func setHomeDirs(info wire.AppInfoReply) {
	if info.FilesDir != "" && os.Getenv("XDG_CONFIG_HOME") == "" {
		os.Setenv("XDG_CONFIG_HOME", info.FilesDir)
	}
	if info.CacheDir != "" && os.Getenv("XDG_CACHE_HOME") == "" {
		os.Setenv("XDG_CACHE_HOME", info.CacheDir)
	}
}
