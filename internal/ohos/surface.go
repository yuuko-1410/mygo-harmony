package ohos

import (
	"time"

	"github.com/egoist/mygo/internal/platform"
)

// surface is the XComponent's OHNativeWindow, which an EGL context of
// package gl draws into.
type surface struct {
	w *window

	native   uintptr
	widthPx  float64
	heightPx float64
	scale    float64
	refresh  float64

	frameWanted bool
	occluded    bool
	gone        bool
}

func (s *surface) setNative(native uintptr, widthPx, heightPx, scale float64) {
	if scale <= 0 {
		scale = 1
	}
	s.native = native
	s.widthPx = widthPx
	s.heightPx = heightPx
	s.scale = scale
}

func (s *surface) Native() platform.SurfaceNative {
	return platform.SurfaceNative{Window: s.native}
}

func (s *surface) Size() (width, height, scale float64) {
	if s.scale <= 0 {
		return 0, 0, 1
	}
	return s.widthPx / s.scale, s.heightPx / s.scale, s.scale
}

func (s *surface) RequestFrame() {
	s.frameWanted = true
	s.w.b.Wake()
}

func (s *surface) RefreshRate() float64 {
	if s.refresh > 0 {
		return s.refresh
	}
	if d := frameInterval(); d > 0 {
		return float64(time.Second) / float64(d)
	}
	return 60
}

// PresentPixels draws frames on the CPU; native UI on OpenHarmony always
// has a GPU renderer, so there is nothing to show here.
func (s *surface) PresentPixels([]byte, int, int, int) {}

func (s *surface) Occluded() bool { return s.occluded }
func (s *surface) WideGamut() bool { return false }
