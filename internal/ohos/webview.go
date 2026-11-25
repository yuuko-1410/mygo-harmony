//go:build openharmony

package ohos

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/internal/platform"
)

// A window whose content is a page: the host shows an ArkUI Web component
// instead of the XComponent that draws a surface, and its controller does
// what the page asks. The app's frontend lives at mygo://localhost/, which
// the host registers as a scheme of its own (customizeSchemes) and hands
// here as it loads (onInterceptRequest): protocol.go serves it.
//
// The page talks to Go through the bridge that internal/bridge injects: the
// host exposes the object mygoAndroid to the page, whose postMessage lands
// in webMessage.

// web is the state of a window's page.
type web struct {
	mu      sync.Mutex
	url     string
	title   string
	loading bool
	canBack bool
	canFwd  bool
	zoom    float64
	ua      string
	bg      *platform.Color
	scripts []platform.UserScript
	ready   bool
	// loaded is closed when the host's Web component first reports itself
	// ready: commands wait for it, as a surface's window waits for its
	// surface.
	loaded chan struct{}
	once   sync.Once
}

// schemeReply is what protocol.go answered for a request the host
// intercepted: the responder writes into it as the handler serves.
type schemeReply struct {
	mu      sync.Mutex
	status  int
	header  map[string][]string
	body    []byte
	replied bool
}

// newWeb makes the page of a window, which the host shows in a Web
// component of its own.
func newWeb(w *window) *web {
	return &web{zoom: 1, loaded: make(chan struct{})}
}

// waitForReady waits for the host's Web component to take commands.
func (v *web) waitForReady(timeout time.Duration) bool {
	select {
	case <-v.loaded:
		return true
	case <-time.After(timeout):
		return false
	}
}

func (v *web) markReady() {
	v.mu.Lock()
	v.ready = true
	v.mu.Unlock()
	v.once.Do(func() { close(v.loaded) })
}

// state reads what the page reports without a round trip to the host.
func (v *web) state() (url, title string, loading, canBack, canFwd bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.url, v.title, v.loading, v.canBack, v.canFwd
}

// Page: the window's page, which the host's Web component follows.

func (w *window) WebViewHandle() uintptr { return uintptr(w.id) }

func (w *window) LoadURL(raw string) {
	if w.web == nil {
		return
	}
	w.web.mu.Lock()
	w.web.url = raw
	w.web.mu.Unlock()
	_, _ = callHost("web.load", map[string]any{"id": w.id, "url": raw})
}

func (w *window) LoadHTML(html, baseURL string) {
	if w.web == nil {
		return
	}
	_, _ = callHost("web.html", map[string]any{"id": w.id, "html": html, "base": baseURL})
}

func (w *window) LoadFile(path, readAccessDir string) {
	u := path
	if !strings.HasPrefix(u, "file://") {
		u = "file://" + path
	}
	w.LoadURL(u)
}

func (w *window) Reload(ignoreCache bool) {
	if w.web == nil {
		return
	}
	_, _ = callHost("web.reload", map[string]any{"id": w.id, "cache": !ignoreCache})
}

func (w *window) StopLoading() {
	if w.web == nil {
		return
	}
	_, _ = callHost("web.stop", map[string]any{"id": w.id})
}

func (w *window) GoBack() {
	if w.web == nil {
		return
	}
	_, _ = callHost("web.back", map[string]any{"id": w.id})
}

func (w *window) GoForward() {
	if w.web == nil {
		return
	}
	_, _ = callHost("web.forward", map[string]any{"id": w.id})
}

func (w *window) CanGoBack() bool {
	if w.web == nil {
		return false
	}
	_, _, _, canBack, _ := w.web.state()
	return canBack
}

func (w *window) CanGoForward() bool {
	if w.web == nil {
		return false
	}
	_, _, _, _, canFwd := w.web.state()
	return canFwd
}

func (w *window) URL() string {
	if w.web == nil {
		return ""
	}
	u, _, _, _, _ := w.web.state()
	return u
}

func (w *window) IsLoading() bool {
	if w.web == nil {
		return false
	}
	_, _, loading, _, _ := w.web.state()
	return loading
}

func (w *window) Eval(js string) {
	if w.web == nil {
		return
	}
	_, _ = callHost("web.eval", map[string]any{"id": w.id, "js": js})
}

func (w *window) SetUserScripts(scripts []platform.UserScript) {
	if w.web == nil {
		return
	}
	w.web.mu.Lock()
	w.web.scripts = scripts
	w.web.mu.Unlock()
	// The documents loaded from now on run them; the host injects them as
	// its proxy and its bridge, at document start.
	names := make([]string, 0, len(scripts))
	for _, s := range scripts {
		names = append(names, s.Source)
	}
	_, _ = callHost("web.scripts", map[string]any{"id": w.id, "scripts": names})
}

func (w *window) SetContentRules([]any) {}

// CallAsyncFunction runs body in the page and reports what it returns, which
// the core arranges to be a string.
func (w *window) CallAsyncFunction(body string, cb func(result string, err error)) {
	if w.web == nil {
		cb("", platform.ErrUnsupported)
		return
	}
	js := "(async function(){" + body + "})().then(v => mygoAndroid.asyncResult(" +
		itoa(w.id) + ", v === undefined ? '' : String(v)))" +
		".catch(e => mygoAndroid.asyncResult(" + itoa(w.id) + ", '\\u0000' + (e && e.message ? e.message : String(e))))"
	w.asyncMu.Lock()
	w.asyncCB = cb
	w.asyncMu.Unlock()
	w.Eval(js)
}

func (w *window) SetZoom(factor float64) {
	if w.web == nil {
		return
	}
	w.web.mu.Lock()
	w.web.zoom = factor
	w.web.mu.Unlock()
	_, _ = callHost("web.zoom", map[string]any{"id": w.id, "factor": factor})
}

func (w *window) Zoom() float64 {
	if w.web == nil {
		return 1
	}
	w.web.mu.Lock()
	defer w.web.mu.Unlock()
	return w.web.zoom
}

func (w *window) SetUserAgent(ua string) {
	if w.web == nil {
		return
	}
	w.web.mu.Lock()
	w.web.ua = ua
	w.web.mu.Unlock()
	_, _ = callHost("web.ua", map[string]any{"id": w.id, "ua": ua})
}

func (w *window) UserAgent() string {
	if w.web == nil {
		return ""
	}
	w.web.mu.Lock()
	defer w.web.mu.Unlock()
	return w.web.ua
}

// webWindowOf finds the window of a page event.
func (b *backend) webWindowOf(id int) *window {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, w := range b.windows {
		if w.id == id {
			return w
		}
	}
	return nil
}

// webNav takes what the host's Web component reports of the page.
func (b *backend) webNav(id, kind int, text string, code int) {
	w := b.webWindowOf(id)
	if w == nil || w.web == nil {
		return
	}
	switch kind {
	case 0: // the load began
		w.web.mu.Lock()
		w.web.loading = true
		w.web.url = text
		w.web.mu.Unlock()
		w.h.NavigationStarted(text)
	case 1: // the load ended
		w.web.mu.Lock()
		w.web.loading = false
		if text != "" {
			w.web.url = text
		}
		w.web.mu.Unlock()
		w.h.LoadFinished()
	case 2: // the title
		w.web.mu.Lock()
		w.web.title = text
		w.web.mu.Unlock()
		w.h.TitleChanged(text)
	case 3: // the URL changed
		w.web.mu.Lock()
		w.web.url = text
		w.web.mu.Unlock()
		w.h.NavigationCommitted(text)
	case 4: // the load failed
		w.web.mu.Lock()
		w.web.loading = false
		w.web.mu.Unlock()
		w.h.LoadFailed(text, code, "")
	case 5, 6: // history
		w.web.mu.Lock()
		w.web.canBack, w.web.canFwd = text == "1" || strings.Contains(text, "b"), code > 0 || w.web.canFwd
		w.web.mu.Unlock()
	}
}

// webHistory takes whether the page can go back and forward.
func (b *backend) webHistory(id int, canBack, canFwd bool) {
	w := b.webWindowOf(id)
	if w == nil || w.web == nil {
		return
	}
	w.web.mu.Lock()
	w.web.canBack, w.web.canFwd = canBack, canFwd
	w.web.mu.Unlock()
}

// webMessage takes what the page's bridge posted.
func (b *backend) webMessage(id int, msg string) {
	w := b.webWindowOf(id)
	if w == nil {
		return
	}
	w.h.Message(msg)
}

// webAsyncResult is what CallAsyncFunction's JavaScript returned.
func (b *backend) webAsyncResult(id int, result string) {
	w := b.webWindowOf(id)
	if w == nil {
		return
	}
	w.asyncMu.Lock()
	cb := w.asyncCB
	w.asyncCB = nil
	w.asyncMu.Unlock()
	if cb == nil {
		return
	}
	if strings.HasPrefix(result, "\x00") {
		cb("", &asyncError{strings.TrimPrefix(result, "\x00")})
		return
	}
	cb(result, nil)
}

type asyncError struct{ msg string }

func (e *asyncError) Error() string { return "mygo: " + e.msg }

// webScheme serves a request the host's Web component intercepted: the
// frontend at mygo://localhost/, or a scheme the app handles itself. The
// host waits for it, as its interceptor answers synchronously, so the work
// runs on the main thread, where protocol.go serves, and this thread waits.
func (b *backend) webScheme(id, reqID int, rawURL, method, headersJSON, bodyB64 string) string {
	done := make(chan string, 1)
	b.push(func() { done <- b.serveScheme(id, rawURL, method, headersJSON, bodyB64) })
	select {
	case out := <-done:
		return out
	case <-time.After(20 * time.Second):
		return `{"status":504,"reason":"Gateway Timeout","mime":"","header":{},"body":""}`
	}
}

// serveScheme runs protocol.go's handler for an intercepted request and
// reports what it answered.
func (b *backend) serveScheme(id int, rawURL, method, headersJSON, bodyB64 string) string {
	w := b.webWindowOf(id)
	if w == nil {
		return schemeJSON(404, nil, nil)
	}
	header := map[string][]string{}
	if headersJSON != "" {
		var list []struct {
			K string `json:"k"`
			V string `json:"v"`
		}
		if json.Unmarshal([]byte(headersJSON), &list) == nil {
			for _, h := range list {
				header[h.K] = append(header[h.K], h.V)
			}
		}
	}
	var body []byte
	if bodyB64 != "" {
		body, _ = base64.StdEncoding.DecodeString(bodyB64)
	}
	reply := &schemeReply{}
	req := &platform.SchemeRequest{
		Context: context.Background(),
		Method:  method,
		URL:     rawURL,
		Header:  header,
		Responder: &schemeResponder{
			reply: reply,
		},
	}
	if len(body) > 0 {
		req.Body = platform.BytesBody(body)
	}
	w.h.SchemeRequest(req)
	reply.mu.Lock()
	defer reply.mu.Unlock()
	status, headerOut, bodyOut := reply.status, reply.header, reply.body
	if !reply.replied || status == 0 {
		// A handler that says nothing serves nothing, as a request of a
		// scheme nobody registered does.
		return schemeJSON(404, nil, nil)
	}
	return schemeJSON(status, headerOut, bodyOut)
}

// schemeResponder is a SchemeRequest's, which collects the status, the
// header and the body of what protocol.go wrote.
type schemeResponder struct {
	reply *schemeReply
}

func (r *schemeResponder) Respond(status int, header map[string][]string) {
	r.reply.mu.Lock()
	r.reply.status, r.reply.header = status, header
	r.reply.mu.Unlock()
}

func (r *schemeResponder) Write(p []byte) {
	r.reply.mu.Lock()
	r.reply.body = append(r.reply.body, p...)
	r.reply.mu.Unlock()
}

func (r *schemeResponder) Finish() {
	r.reply.mu.Lock()
	r.reply.replied = true
	r.reply.mu.Unlock()
}

func (r *schemeResponder) Fail(error) {
	r.reply.mu.Lock()
	r.reply.replied = true
	r.reply.mu.Unlock()
}

// schemeJSON is what the host takes for a response: status, header, mime and
// the body in base64.
func schemeJSON(status int, header map[string][]string, body []byte) string {
	if header == nil {
		// The host takes an object, not a null.
		header = map[string][]string{}
	}
	msg := struct {
		Status int                 `json:"status"`
		Reason string              `json:"reason"`
		Mime   string              `json:"mime"`
		Header map[string][]string `json:"header"`
		Body   string              `json:"body"`
	}{Status: status, Reason: reasonOf(status), Header: header,
		Body: base64.StdEncoding.EncodeToString(body)}
	msg.Mime = mimeOf(header)
	data, err := json.Marshal(msg)
	if err != nil {
		return `{"status":500,"reason":"Internal Server Error","mime":"","header":{},"body":""}`
	}
	return string(data)
}

// mimeOf reads a response's content type.
func mimeOf(header map[string][]string) string {
	for k, v := range header {
		if strings.EqualFold(k, "content-type") && len(v) > 0 {
			return strings.TrimSpace(strings.SplitN(v[0], ";", 2)[0])
		}
	}
	return ""
}

// webCloseRequest takes a page that asks to close its window.
func (b *backend) webCloseRequest(id int) {
	w := b.webWindowOf(id)
	if w == nil {
		return
	}
	w.h.ClosedByPage()
}

// itoa is strconv.Itoa without the import in every file that needs it.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// resolveWebURL keeps a page's URL as the app names it, for the URL() the
// page reads: mygo://localhost/ stays, as the host registers the scheme.
func resolveWebURL(raw string) string {
	if raw == "" {
		return ""
	}
	if u, err := url.Parse(raw); err == nil {
		return u.String()
	}
	return raw
}

// reasonOf names an HTTP status, as WebResourceResponse's reason shows it.
func reasonOf(status int) string {
	switch status {
	case 200:
		return "OK"
	case 204:
		return "No Content"
	case 301:
		return "Moved Permanently"
	case 302:
		return "Found"
	case 304:
		return "Not Modified"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 500:
		return "Internal Server Error"
	}
	return ""
}
