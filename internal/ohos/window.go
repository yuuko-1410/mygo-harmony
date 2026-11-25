//go:build openharmony

package ohos

import (
	"sync"
	"github.com/egoist/mygo/internal/platform"
)

// window is one native-UI window, drawn into the XComponent's surface.
type window struct {
	b *backend
	h platform.WindowHandler
	s *surface

	title       string
	id          int
	bounds      platform.Rect
	visible     bool
	focused     bool
	focusSent   bool
	frameLogged bool
	resizable   bool
	closed      bool

	// web is the page the window shows instead of a surface: a window of a
	// web UI has neither an XComponent nor frames of its own.
	web *web
	// asyncCB waits for what CallAsyncFunction ran to return.
	asyncMu sync.Mutex
	asyncCB func(result string, err error)
}

func (w *window) Handle() uintptr           { return w.s.native }
func (w *window) Surface() platform.Surface { return w.s }

func (w *window) SetTitle(title string) { w.title = title }
func (w *window) Title() string         { return w.title }

func (w *window) SetBounds(r platform.Rect) { w.bounds = r }
func (w *window) Bounds() platform.Rect     { return w.bounds }

func (w *window) SetContentBounds(r platform.Rect) { w.bounds = r }
func (w *window) ContentBounds() platform.Rect     { return w.bounds }

func (w *window) Show() {
	w.visible = true
	w.s.frameWanted = true
	w.b.Wake()
}

func (w *window) ShowInactive() { w.Show() }

func (w *window) Hide() {
	w.visible = false
	w.focused = false
}

func (w *window) IsVisible() bool { return w.visible }

func (w *window) Focus() {
	w.focused = true
	w.b.push(func() { w.h.Focused() })
}

func (w *window) Blur() {
	w.focused = false
	w.b.push(func() { w.h.Blurred() })
}

func (w *window) IsFocused() bool { return w.focused }

func (w *window) Close() {
	if w.closed {
		return
	}
	if w.h.ShouldClose() {
		w.closed = true
		w.visible = false
		go func(id int) { _, _ = callHost("window.close", map[string]int{"id": id}) }(w.id)
		w.h.Closed()
	}
}

func (w *window) SetBackgroundColor(platform.Color) {}
func (w *window) SetOpacity(float64)                {}
func (w *window) Opacity() float64                  { return 1 }
func (w *window) CornerRadius() float64             { return 0 }
func (w *window) IsResizable() bool                 { return w.resizable }
func (w *window) SetResizable(v bool)               { w.resizable = v }
func (w *window) SetFullScreen(bool)                {}
func (w *window) IsFullScreen() bool                { return false }
func (w *window) Center()                           {}
func (w *window) Maximize()                         {}
func (w *window) IsMaximized() bool                 { return false }
func (w *window) Minimize()                         { w.visible = false }
func (w *window) IsMinimized() bool                 { return !w.visible }

// deliverFrame hands a frame request to the content.
func (w *window) deliverFrame() {
	if !w.focusSent {
		w.focusSent = true
		w.h.SurfaceEvent(platform.SurfaceEvent{Kind: platform.SurfaceFocus})
	}
	if !w.frameLogged {
		w.frameLogged = true
	}
	if w.closed || w.s.gone {
		return
	}
	w.h.SurfaceEvent(platform.SurfaceEvent{Kind: platform.SurfaceFrame})
}

// deliver hands an input event to the content.
func (w *window) deliver(ev platform.SurfaceEvent) {
	if !w.focusSent {
		w.focusSent = true
		w.h.SurfaceEvent(platform.SurfaceEvent{Kind: platform.SurfaceFocus})
	}
	if !w.frameLogged {
		w.frameLogged = true
	}
	if w.closed || w.s.gone {
		return
	}
	w.h.SurfaceEvent(ev)
}
