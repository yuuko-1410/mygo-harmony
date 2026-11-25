//go:build openharmony || (linux && ohos)

package ohos

import (
	"encoding/json"

	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/internal/unsupported"
)

// theme follows the system appearance the host reports.
type theme struct{ unsupported.Theme }

type themeInfo struct {
	Dark bool `json:"dark"`
}

func readTheme() themeInfo {
	var t themeInfo
	raw, err := callHost("theme.info", nil)
	if err != nil || len(raw) == 0 {
		return t
	}
	_ = json.Unmarshal(raw, &t)
	return t
}

func (theme) IsDark() bool { return readTheme().Dark }

func (theme) SetSource(source string) {
	mode := "system"
	switch source {
	case "light":
		mode = "light"
	case "dark":
		mode = "dark"
	}
	_, _ = callHost("theme.set", map[string]string{"mode": mode})
}

func (theme) UIFont() string { return "HarmonyOS Sans" }

func (theme) FontRendering() platform.FontRendering { return platform.FontRendering{} }

func (theme) Preferences() platform.Preferences { return platform.Preferences{} }

func (b *backend) Theme() platform.Theme { return theme{} }
