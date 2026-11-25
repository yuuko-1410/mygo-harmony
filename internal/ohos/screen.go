//go:build openharmony || (linux && ohos)

package ohos

import (
	"encoding/json"

	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/internal/unsupported"
)

// screen asks the host about the display: HarmonyOS tells pixel size,
// density and refresh rate, which MyGo turns into DIPs.
type screen struct{ unsupported.Screen }

type displayInfo struct {
	WidthPx     float64 `json:"widthPx"`
	HeightPx    float64 `json:"heightPx"`
	Density     float64 `json:"density"`
	RefreshRate float64 `json:"refreshRate"`
}

func readDisplay() displayInfo {
	var d displayInfo
	raw, err := callHost("screen.info", nil)
	if err != nil || len(raw) == 0 {
		return d
	}
	_ = json.Unmarshal(raw, &d)
	if d.Density <= 0 {
		d.Density = 1
	}
	return d
}

func (screen) Displays() []platform.Display {
	d := readDisplay()
	scale := d.Density
	w := int(d.WidthPx / scale)
	h := int(d.HeightPx / scale)
	return []platform.Display{{
		ID:          1,
		Label:       "HarmonyOS display",
		Bounds:      platform.Rect{Width: w, Height: h},
		WorkArea:    platform.Rect{Width: w, Height: h},
		ScaleFactor: scale,
		Primary:     true,
	}}
}

func (screen) CursorPoint() platform.Point {
	d := readDisplay()
	return platform.Point{X: int(d.WidthPx / d.Density / 2), Y: int(d.HeightPx / d.Density / 2)}
}

func (b *backend) Screen() platform.Screen { return screen{} }
