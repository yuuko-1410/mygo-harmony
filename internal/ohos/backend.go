// Package ohos is MyGo's OpenHarmony (HarmonyOS) backend: a HarmonyOS app's
// native module makes an XComponent, hands its OHNativeWindow to Go through
// the C API in api.go, and this package runs MyGo's loop on that window,
// drawing native UI with OpenGL ES over EGL.
//
// What is not here yet (inert, through internal/unsupported): web pages,
// menus, dialogs, clipboard, notifications, IME and accessibility.
package ohos

import (
	"log"
	"errors"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/internal/unsupported"
)

// backend runs one application.
type backend struct {
	*unsupported.Backend

	mu      sync.Mutex
	cond    *sync.Cond
	wake    chan struct{}
	queue   []func()
	windows []*window
	quit    bool
	tid     int

	h    platform.AppHandler
	opts platform.AppOptions
}

// New returns the OpenHarmony backend.
func New() platform.Backend {
	b := &backend{
		Backend: unsupported.New(),
		wake:    make(chan struct{}, 1),
		tid:     unix.Gettid(),
	}
	b.cond = sync.NewCond(&b.mu)
	setActive(b)
	return b
}

func (*backend) Name() string { return "openharmony/xcomponent" }

func (b *backend) Init(h platform.AppHandler, opts platform.AppOptions) error {
	b.mu.Lock()
	b.h = h
	b.opts = opts
	b.mu.Unlock()
	return nil
}

func (b *backend) IsMainThread() bool {
	b.mu.Lock()
	tid := b.tid
	b.mu.Unlock()
	return tid != 0 && unix.Gettid() == tid
}

func (b *backend) Signal() {
	b.mu.Lock()
	b.queue = append(b.queue, func() { b.h.Dispatch() })
	b.mu.Unlock()
	b.Wake()
}

func (b *backend) Step() {
	select {
	case <-b.wake:
	case <-time.After(10 * time.Millisecond):
	}
}

func (b *backend) Wake() {
	select {
	case b.wake <- struct{}{}:
	default:
	}
	b.mu.Lock()
	b.cond.Broadcast()
	b.mu.Unlock()
}

func (b *backend) Quit() {
	b.mu.Lock()
	b.quit = true
	b.mu.Unlock()
	b.Wake()
}

// Run runs the event loop on the calling (main) thread.
func (b *backend) Run() error {
	b.mu.Lock()
	b.tid = unix.Gettid()
	b.mu.Unlock()

	b.h.Ready()

	tick := time.NewTicker(frameInterval())
	defer tick.Stop()
	for {
		b.mu.Lock()
		if b.quit {
			b.mu.Unlock()
			return nil
		}
		queue := b.queue
		b.queue = nil
		var frames []*window
		for _, w := range b.windows {
			if w.s.frameWanted && !w.s.gone && w.visible && !w.s.occluded {
				w.s.frameWanted = false
				frames = append(frames, w)
			}
		}
		b.mu.Unlock()

		for _, f := range queue {
			f()
		}
		for _, w := range frames {
			w.deliverFrame()
		}
		select {
		case <-b.wake:
		case <-tick.C:
		}
	}
}

// push schedules f to run on the main thread.
func (b *backend) push(f func()) {
	b.mu.Lock()
	if b.h != nil {
		b.queue = append(b.queue, f)
	}
	b.mu.Unlock()
	b.Wake()
}

func (b *backend) NewWindow(opts *platform.WindowOptions, h platform.WindowHandler) (platform.Window, error) {
	w := &window{
		b:       b,
		h:       h,
		title:   opts.Title,
		visible: true,
		focused: true,
		bounds: platform.Rect{X: opts.X, Y: opts.Y, Width: opts.Width, Height: opts.Height},
		resizable: true,
	}
	w.s = &surface{w: w, refresh: float64(time.Second) / float64(frameInterval())}

	kind, formName := readDevice()
	log.Printf("ohos: form %s", formName)

	var native uintptr
	var width, height, scale float64
	var ok bool
	b.mu.Lock()
	first := len(b.windows) == 0 || kind == formPhone
	id := len(b.windows)
	w.id = id
	b.mu.Unlock()
	if first {
		native, width, height, scale, ok = takeNativeSurface(5 * time.Second)
	} else {
		log.Printf("ohos: asking host for window %d", id)
		if _, err := callHost("window.create", map[string]int{"id": id}); err != nil {
			log.Printf("ohos: window.create failed: %v", err)
		}
		native, width, height, scale, ok = takeSurfaceByID(uintptr(id), 10*time.Second)
		log.Printf("ohos: window %d surface=%#x ok=%v", id, native, ok)
	}
	if !ok {
		return nil, errors.New("ohos: no native surface from the host (is the XComponent mounted?)")
	}
	w.s.setNative(native, width, height, scale)

	b.mu.Lock()
	b.windows = append(b.windows, w)
	if first && len(b.windows) > 1 {
		for _, older := range b.windows[:len(b.windows)-1] {
			older.visible = false
			older.s.frameWanted = false
		}
	}
	b.mu.Unlock()
	b.Wake()

	w.h.Resized()
	w.s.frameWanted = true
	w.s.SetTextInput(platform.TextInputState{Active: false})
	b.Wake()
	return w, nil
}
