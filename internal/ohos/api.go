//go:build openharmony

package ohos

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"math"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/egoist/mygo/internal/platform"
)

// active is the running backend, if any: the host's callbacks find it
// here, since C cannot call Go methods.
var (
	activeMu sync.Mutex
	active   *backend
)

// surfaceMu guards the native surface the host reports; ArkTS may mount the
// XComponent before or after the app starts.
var (
	surfaceMu     sync.Mutex
	surfaceNative uintptr
	surfaceW      float64
	surfaceH      float64
	surfaceScale  float64
	surfaceSet    bool
	surfaceByID   map[uintptr]nativeSurface
	surfaceCh     = make(chan struct{}, 1)
)

func setActive(b *backend) {
	activeMu.Lock()
	active = b
	activeMu.Unlock()
}

func current() *backend {
	activeMu.Lock()
	defer activeMu.Unlock()
	return active
}

func notifySurface() {
	select {
	case surfaceCh <- struct{}{}:
	default:
	}
}

// takeNativeSurface waits until the host reported a native window.
func takeNativeSurface(timeout time.Duration) (uintptr, float64, float64, float64, bool) {
	deadline := time.Now().Add(timeout)
	for {
		surfaceMu.Lock()
		if surfaceSet && surfaceNative != 0 {
			n, w, h, s := surfaceNative, surfaceW, surfaceH, surfaceScale
			surfaceMu.Unlock()
			return n, w, h, s, true
		}
		surfaceMu.Unlock()
		if time.Now().After(deadline) {
			return 0, 0, 0, 0, false
		}
		select {
		case <-surfaceCh:
		case <-time.After(20 * time.Millisecond):
		}
	}
}

//go:linkname mainMain main.main
func mainMain()

//export mygo_start
func mygo_start(filesDir *C.char) {
	dir := ""
	if filesDir != nil {
		dir = C.GoString(filesDir)
	}
	_ = dir
	redirectOutput()
	go func() {
		runtime.LockOSThread()
		mainMain()
	}()
}

//export mygo_surface_created
func mygo_surface_created(native C.uintptr_t, width, height, scale C.double) {
	surfaceMu.Lock()
	surfaceNative = uintptr(native)
	surfaceW = float64(width)
	surfaceH = float64(height)
	surfaceScale = float64(scale)
	surfaceSet = true
	surfaceMu.Unlock()
	notifySurface()

	if b := current(); b != nil {
		b.push(func() { b.resizeSurface(uintptr(native), float64(width), float64(height), float64(scale)) })
	}
}

//export mygo_surface_resized
func mygo_surface_resized(width, height, scale C.double) {
	surfaceMu.Lock()
	surfaceW = float64(width)
	surfaceH = float64(height)
	surfaceScale = float64(scale)
	surfaceMu.Unlock()

	if b := current(); b != nil {
		b.push(func() { b.resizeSurface(0, float64(width), float64(height), float64(scale)) })
	}
}

//export mygo_surface_destroyed
func mygo_surface_destroyed() {
	// Keep windows bound: the framework recreates surfaces as components
	// mount, and a window that lost its surface only skips frames.
}

// touchDrag tracks one finger: a drag past the slop scrolls what it is
// over, and the press it began with clicks nothing (as Android's host
// cancels the press when its scroll gesture takes over).
type touchDrag struct {
	down     bool
	dragging bool
	x, y     float64
	startX   float64
	startY   float64
	// The finger's velocity in DIPs per millisecond, smoothed over the
	// moves that came before, and when the last of them came.
	vx, vy float64
	last   time.Time
	lastX  float64
	lastY  float64
	// gen numbers the drags, so that the momentum of one that ended stops
	// for the one that begins.
	gen int
}

var (
	drag   touchDrag
	dragMu sync.Mutex
)

const (
	dragSlop = 6 // DIPs
	// momentumTau is how long, in milliseconds, the fling of a finger takes
	// to slow to 1/e of its speed: macOS's scroll views settle in about a
	// third of a second.
	momentumTau = 320
	// momentumFrame is how often the fling moves, and momentumStop the
	// speed, in DIPs per millisecond, below which it comes to rest.
	momentumFrame = 8
	momentumStop  = 0.02
)

//export mygo_touch
func mygo_touch(phase C.int, id C.int, x, y, pressure C.double) {
	b := current()
	if b == nil {
		return
	}
	px, py := float64(x), float64(y)
	now := time.Now()
	var kind platform.SurfaceEventKind
	switch int(phase) {
	case 0:
		kind = platform.PointerDown
	case 1:
		kind = platform.PointerMove
	case 2:
		kind = platform.PointerUp
	default:
		kind = platform.PointerCancel
	}
	ev := platform.SurfaceEvent{
		Kind:     kind,
		X:        px,
		Y:        py,
		Pointer:  platform.PointerTouch,
		Touch:    true,
		Pressure: float64(pressure),
		ID:       uint64(id),
	}
	var scroll *platform.SurfaceEvent
	wasDragging := drag.dragging
	dragMu.Lock()
	switch kind {
	case platform.PointerDown:
		// The finger stops what the last one flung.
		drag.gen++
		drag = touchDrag{down: true, x: px, y: py, startX: px, startY: py,
			last: now, lastX: px, lastY: py, gen: drag.gen}
	case platform.PointerMove:
		if drag.down {
			dx, dy := px-drag.x, py-drag.y
			drag.x, drag.y = px, py
			if !drag.dragging {
				if math.Hypot(px-drag.startX, py-drag.startY) < dragSlop {
					break
				}
				drag.dragging = true
				drag.last, drag.lastX, drag.lastY = now, px, py
				// The press ends without a click, as a scroll gesture took it.
				b.push(func() {
					b.deliver(platform.SurfaceEvent{Kind: platform.PointerUp, X: -1e6, Y: -1e6, Touch: true, Canceled: true})
					b.deliver(platform.SurfaceEvent{Kind: platform.PointerLeave, Touch: true})
				})
			}
			// The finger's speed, over the time since the last move, keeping
			// half of the speed it had: a fling that ends slowly still ends.
			if dt := now.Sub(drag.last).Seconds() * 1000; dt > 0.5 {
				ivx := (px - drag.lastX) / dt
				ivy := (py - drag.lastY) / dt
				drag.vx = 0.4*drag.vx + 0.6*ivx
				drag.vy = 0.4*drag.vy + 0.6*ivy
				drag.last, drag.lastX, drag.lastY = now, px, py
			}
			scroll = &platform.SurfaceEvent{Kind: platform.PointerScroll, X: px, Y: py,
				DX: -dx, DY: -dy, Precise: true}
		}
	case platform.PointerUp, platform.PointerCancel:
		flung, vx, vy, gen := drag.dragging && kind == platform.PointerUp, drag.vx, drag.vy, drag.gen
		if now.Sub(drag.last) > 150*time.Millisecond {
			flung = false // the finger rested before it lifted
		}
		drag.down, drag.dragging = false, false
		dragMu.Unlock()
		if flung && math.Hypot(vx, vy) >= momentumStop*2 {
			go fling(b, gen, px, py, vx, vy)
		}
		dragMu.Lock()
	default:
		drag.down, drag.dragging = false, false
	}
	dragMu.Unlock()
	push := func() {
		if scroll != nil {
			b.deliver(*scroll)
			return
		}
		if kind == platform.PointerUp && scroll == nil && wasDragging {
			return // the drag already ended the press
		}
		b.deliver(ev)
	}
	b.push(push)
}

// fling scrolls on after the finger leaves, slower and slower, as a scroll
// view of macOS does: the speed it had falls to 1/e every momentumTau,
// until it rests or another finger comes down.
func fling(b *backend, gen int, x, y, vx, vy float64) {
	last := time.Now()
	for {
		time.Sleep(momentumFrame * time.Millisecond)
		now := time.Now()
		dt := now.Sub(last).Seconds() * 1000
		last = now
		decay := math.Exp(-dt / momentumTau)
		vx *= decay
		vy *= decay
		if math.Hypot(vx, vy) < momentumStop {
			return
		}
		dragMu.Lock()
		taken := drag.gen != gen || drag.down
		dragMu.Unlock()
		if taken {
			return // another finger took it
		}
		dx, dy := vx*dt, vy*dt
		b.push(func() {
			dragMu.Lock()
			taken := drag.gen != gen
			dragMu.Unlock()
			if taken {
				return
			}
			b.deliver(platform.SurfaceEvent{Kind: platform.PointerScroll, X: x, Y: y,
				DX: -dx, DY: -dy, Precise: true})
		})
	}
}

// The wheel: a notch of it is a push that glides to a stop, as scrolling
// does in macOS. Each notch adds to the speed, and a frame moves by the
// speed, which falls to 1/e every wheelTau: the notches of a spin add up,
// and the content settles a moment after the wheel rests.
var (
	wheelMu      sync.Mutex
	wheelVX      float64
	wheelVY      float64
	wheelX       float64
	wheelY       float64
	wheelGliding bool
)

const (
	wheelTau   = 130.0 // milliseconds
	wheelStop  = 0.05  // DIPs per millisecond
	wheelFrame = 8
)

//export mygo_scroll_at
func mygo_scroll_at(dx, dy, x, y C.double) {
	b := current()
	if b == nil {
		return
	}
	// A part of the notch goes at once, as the wheel expects, and the rest
	// glides: what covers the rest is the speed it falls from.
	const now = 0.35
	wheelMu.Lock()
	wheelX, wheelY = float64(x), float64(y)
	wheelVX += float64(dx) * (1 - now) / wheelTau
	wheelVY += float64(dy) * (1 - now) / wheelTau
	start := !wheelGliding
	wheelGliding = true
	wheelMu.Unlock()
	b.push(func() {
		b.deliver(platform.SurfaceEvent{Kind: platform.PointerScroll, X: float64(x), Y: float64(y),
			DX: float64(dx) * now, DY: float64(dy) * now, Precise: true})
	})
	if start {
		go glideWheel(b)
	}
}

// glideWheel moves the content the wheel pushed, slower and slower.
func glideWheel(b *backend) {
	last := time.Now()
	for {
		time.Sleep(wheelFrame * time.Millisecond)
		now := time.Now()
		dt := now.Sub(last).Seconds() * 1000
		last = now
		if dt <= 0 {
			continue
		}
		wheelMu.Lock()
		decay := math.Exp(-dt / wheelTau)
		wheelVX *= decay
		wheelVY *= decay
		dx, dy := wheelVX*dt, wheelVY*dt
		x, y := wheelX, wheelY
		rest := math.Hypot(wheelVX, wheelVY) < wheelStop
		if rest {
			wheelGliding = false
			wheelVX, wheelVY = 0, 0
		}
		wheelMu.Unlock()
		if rest {
			return
		}
		b.push(func() {
			b.deliver(platform.SurfaceEvent{Kind: platform.PointerScroll, X: x, Y: y,
				DX: dx, DY: dy, Precise: true})
		})
	}
}

//export mygo_scroll
func mygo_scroll(dx, dy C.double) {
	b := current()
	if b == nil {
		return
	}
	ev := platform.SurfaceEvent{Kind: platform.PointerScroll, DX: float64(dx), DY: float64(dy), Precise: true}
	b.push(func() { b.deliver(ev) })
}

//export mygo_quit
func mygo_quit() {
	if b := current(); b != nil {
		b.Quit()
	}
}

// resizeSurface applies a new native window and size to every window.
func (b *backend) resizeSurface(native uintptr, widthPx, heightPx, scale float64) {
	b.mu.Lock()
	ws := append([]*window(nil), b.windows...)
	b.mu.Unlock()
	for _, w := range ws {
		if native == 0 {
			native = w.s.native
		}
		renew := w.s.native != native || w.s.widthPx != widthPx || w.s.heightPx != heightPx
		w.s.setNative(native, widthPx, heightPx, scale)
		w.s.gone = false
		w.s.frameWanted = true
		if renew {
			// The EGL surface draws into the window's buffers: a new size or
			// a new window needs one made on them again.
			w.deliver(platform.SurfaceEvent{Kind: platform.SurfaceRenew})
		}
		w.h.Resized()
	}
	b.Wake()
}

// deliver hands an event to the first window.
func (b *backend) deliver(ev platform.SurfaceEvent) {
	b.mu.Lock()
	var w *window
	if len(b.windows) > 0 {
		w = b.windows[0]
	}
	b.mu.Unlock()
	if w != nil {
		w.deliver(ev)
	}
}

// mygo_frame is called by the host's XComponent frame callback on every
// display refresh: the loop then delivers the frame the content asked for.
//
//export mygo_frame
func mygo_frame() {
	if b := current(); b != nil {
		b.Wake()
	}
}

// mygo_surface_shown tells whether the XComponent is on screen: a hidden
// one is not drawn, as the app is in the background.
//
//export mygo_surface_shown
func mygo_surface_shown(shown C.int) {
	b := current()
	if b == nil {
		return
	}
	b.mu.Lock()
	ws := append([]*window(nil), b.windows...)
	b.mu.Unlock()
	for _, w := range ws {
		w.s.occluded = shown == 0
		if shown == 0 {
			b.h.DidResignActive()
		} else {
			b.h.DidBecomeActive()
		}
		if shown != 0 {
			w.s.frameWanted = true
		}
	}
	b.Wake()
}

// mygo_mouse delivers a mouse event, in DIPs: phase 0 press, 1 move,
// 2 release, 3 cancel.
//
//export mygo_mouse
func mygo_mouse(phase C.int, x, y C.double, button C.int) {
	b := current()
	if b == nil {
		return
	}
	var kind platform.SurfaceEventKind
	switch int(phase) {
	case 0:
		kind = platform.PointerDown
	case 2:
		kind = platform.PointerUp
	case 3:
		kind = platform.PointerCancel
	default:
		kind = platform.PointerMove
	}
	ev := platform.SurfaceEvent{
		Kind:    kind,
		X:       float64(x),
		Y:       float64(y),
		Button:  int(button),
		Pointer: platform.PointerMouse,
	}
	b.push(func() { b.deliver(ev) })
}

// mygo_key delivers a key event by its HarmonyOS key code.
//
//export mygo_key
func mygo_key(down C.int, code C.int, text *C.char) {
	b := current()
	if b == nil {
		return
	}
	kind := platform.KeyPressed
	if down == 0 {
		kind = platform.KeyReleased
	}
	ev := platform.SurfaceEvent{Kind: kind, Code: platform.KeyCode(code)}
	if text != nil {
		ev.Text = C.GoString(text)
	}
	b.push(func() { b.deliver(ev) })
}

// mygo_surface_created_id is mygo_surface_created for a window identified by
// its XComponent: a host with several XComponents makes one window each.
// The surface of a window that the content has not made yet waits for it in
// surfaceByID, which NewWindow takes (takeSurfaceByID).
//
//export mygo_surface_created_id
func mygo_surface_created_id(id C.ulonglong, native C.uintptr_t, width, height, scale C.double) {
	surfaceMu.Lock()
	if surfaceByID == nil {
		surfaceByID = map[uintptr]nativeSurface{}
	}
	surfaceByID[uintptr(id)] = nativeSurface{
		native: uintptr(native),
		width:  float64(width),
		height: float64(height),
		scale:  float64(scale),
	}
	surfaceMu.Unlock()
	if uintptr(id) == 0 {
		// The first window's, which a host of one XComponent tells this way.
		mygo_surface_created(native, width, height, scale)
		return
	}
	b := current()
	if b == nil {
		return
	}
	b.push(func() {
		b.mu.Lock()
		var w *window
		for _, cand := range b.windows {
			if cand.id == int(id) {
				w = cand
				break
			}
		}
		b.mu.Unlock()
		if w == nil {
			return // NewWindow takes it when it comes
		}
		renew := w.s.native != uintptr(native)
		w.s.setNative(uintptr(native), float64(width), float64(height), float64(scale))
		w.s.gone = false
		w.s.frameWanted = true
		if renew {
			w.deliver(platform.SurfaceEvent{Kind: platform.SurfaceRenew})
		}
		w.h.Resized()
	})
	b.Wake()
}

// mygo_surface_resized_id resizes the window of one XComponent only: a host
// with several XComponents resizes them as they mount and move.
//
// mygo_resize_id resizes the window of one XComponent: the host tells the
// size its component has, in its own units, of the window of that id.
//
//export mygo_resize_id
func mygo_resize_id(id C.int, width, height, scale C.double) {
	b := current()
	if b == nil {
		return
	}
	b.push(func() {
		b.mu.Lock()
		var w *window
		for _, cand := range b.windows {
			if cand.id == int(id) {
				w = cand
				break
			}
		}
		b.mu.Unlock()
		if w == nil || w.s.scale <= 0 {
			return
		}
		s := float64(scale)
		if s <= 0 {
			s = w.s.scale
		}
		widthPx, heightPx := float64(width)*s, float64(height)*s
		renew := w.s.widthPx != widthPx || w.s.heightPx != heightPx
		w.s.setNative(w.s.native, widthPx, heightPx, s)
		w.s.gone = false
		w.s.frameWanted = true
		if renew {
			w.deliver(platform.SurfaceEvent{Kind: platform.SurfaceRenew})
		}
		w.h.Resized()
	})
	b.Wake()
}

//export mygo_surface_resized_id
func mygo_surface_resized_id(id C.ulonglong, width, height, scale C.double) {
	b := current()
	if b == nil {
		return
	}
	b.push(func() {
		b.mu.Lock()
		var w *window
		for _, cand := range b.windows {
			if cand.id == int(id) {
				w = cand
				break
			}
		}
		b.mu.Unlock()
		if w == nil {
			return
		}
		renew := w.s.widthPx != float64(width) || w.s.heightPx != float64(height)
		w.s.setNative(w.s.native, float64(width), float64(height), float64(scale))
		w.s.gone = false
		w.s.frameWanted = true
		if renew {
			w.deliver(platform.SurfaceEvent{Kind: platform.SurfaceRenew})
		}
		w.h.Resized()
	})
}

// mygo_window_closed is called when the host destroyed a window's own
// window: the user pressed its close button.
//
//export mygo_window_closed
func mygo_window_closed(id C.int) {
	b := current()
	if b == nil {
		return
	}
	b.push(func() {
		b.mu.Lock()
		var w *window
		for _, cand := range b.windows {
			if cand.id == int(id) {
				w = cand
				break
			}
		}
		b.mu.Unlock()
		if w == nil || w.closed {
			return
		}
		w.closed = true
		w.visible = false
		w.s.gone = true
		w.h.Closed()
	})
}

// nativeSurface is a surface the host made, waiting for the window it
// belongs to.
type nativeSurface struct {
	native        uintptr
	width, height float64
	scale         float64
}

// takeSurfaceByID waits for the surface of the window with the given id,
// which the host makes as it mounts that window's XComponent.
func takeSurfaceByID(id uintptr, timeout time.Duration) (native uintptr, width, height, scale float64, ok bool) {
	deadline := time.Now().Add(timeout)
	for {
		surfaceMu.Lock()
		ns, have := surfaceByID[id]
		surfaceMu.Unlock()
		if have && ns.native != 0 {
			return ns.native, ns.width, ns.height, ns.scale, true
		}
		if !time.Now().Before(deadline) {
			return 0, 0, 0, 0, false
		}
		time.Sleep(5 * time.Millisecond)
	}
}

//export mygo_web_ready
func mygo_web_ready(id C.int) {
	b := current()
	if b == nil {
		return
	}
	b.push(func() {
		if w := b.webWindowOf(int(id)); w != nil && w.web != nil {
			w.web.markReady()
		}
	})
}

//export mygo_web_nav
func mygo_web_nav(id, kind C.int, text *C.char, code C.int) {
	b := current()
	if b == nil {
		return
	}
	s := ""
	if text != nil {
		s = C.GoString(text)
	}
	b.push(func() { b.webNav(int(id), int(kind), s, int(code)) })
}

//export mygo_web_history
func mygo_web_history(id C.int, canBack, canFwd C.int) {
	b := current()
	if b == nil {
		return
	}
	b.push(func() { b.webHistory(int(id), canBack != 0, canFwd != 0) })
}

//export mygo_web_message
func mygo_web_message(id C.int, msg *C.char) {
	b := current()
	if b == nil || msg == nil {
		return
	}
	s := C.GoString(msg)
	b.push(func() { b.webMessage(int(id), s) })
}

//export mygo_web_async_result
func mygo_web_async_result(id C.int, result *C.char) {
	b := current()
	if b == nil || result == nil {
		return
	}
	s := C.GoString(result)
	b.push(func() { b.webAsyncResult(int(id), s) })
}

// mygo_web_scheme serves a request the host intercepted and returns what
// protocol.go answered, as JSON: the host's interceptor answers at once, so
// this waits for the main thread, and the host frees the string.
//
//export mygo_web_scheme
func mygo_web_scheme(id C.int, url, method, header, body *C.char) *C.char {
	b := current()
	if b == nil {
		return C.CString("")
	}
	arg := func(p *C.char) string {
		if p == nil {
			return ""
		}
		return C.GoString(p)
	}
	u, m, h, bd := arg(url), arg(method), arg(header), arg(body)
	out := b.webScheme(int(id), 0, u, m, h, bd)
	return C.CString(out)
}

//export mygo_web_close_request
func mygo_web_close_request(id C.int) {
	b := current()
	if b == nil {
		return
	}
	b.push(func() { b.webCloseRequest(int(id)) })
}

// mygo_free frees a string this side made for the host, as a served request
// of a scheme the host intercepted.
//
//export mygo_free
func mygo_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}
