//go:build openharmony || (linux && ohos)

package ohos

import (
	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/transfer"
)

func (s *surface) CancelDataDrag() {}

func (s *surface) NewWebView(*platform.WindowOptions, platform.WindowHandler) (platform.WebView, error) {
	return nil, platform.Unsupported("ohos: web views are not supported yet")
}

func (s *surface) PlaceWebViews([]platform.WebViewPlacement) {}

func (s *surface) SetCursor(platform.Cursor) {}

func (s *surface) SetDropFormats([]transfer.Format) {}

func (s *surface) StartDataDrag(platform.DragRequest) {}

func (s *surface) UpdateAccessibility(*platform.AccessTree) {}
