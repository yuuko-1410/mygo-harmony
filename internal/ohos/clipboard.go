//go:build openharmony || (linux && ohos)

package ohos

import (
	"encoding/json"

	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/internal/unsupported"
)

// clipboard is the system clipboard through the host: ArkTS's pasteboard
// answers the calls the platform needs.
type clipboard struct{ unsupported.Clipboard }

func (clipboard) ReadText() string {
	var out struct {
		Text string `json:"text"`
	}
	b, err := callHost("clipboard.read", nil)
	if err != nil || len(b) == 0 {
		return ""
	}
	if json.Unmarshal(b, &out) != nil {
		return ""
	}
	return out.Text
}

func (clipboard) WriteText(text string) {
	_, _ = callHost("clipboard.write", map[string]string{"text": text})
}

func (clipboard) ReadHTML() string {
	var out struct {
		HTML string `json:"html"`
	}
	b, err := callHost("clipboard.readHTML", nil)
	if err != nil || len(b) == 0 {
		return ""
	}
	if json.Unmarshal(b, &out) != nil {
		return ""
	}
	return out.HTML
}

func (clipboard) WriteHTML(html string) {
	_, _ = callHost("clipboard.writeHTML", map[string]string{"html": html})
}

func (clipboard) ReadImage() []byte {
	var out struct {
		PNG []byte `json:"png"`
	}
	b, err := callHost("clipboard.readImage", nil)
	if err != nil || len(b) == 0 {
		return nil
	}
	if json.Unmarshal(b, &out) != nil {
		return nil
	}
	return out.PNG
}

func (clipboard) WriteImage(png []byte) error {
	_, err := callHost("clipboard.writeImage", map[string][]byte{"png": png})
	return err
}

func (clipboard) Clear() { clipboard{}.WriteText("") }

func (b *backend) Clipboard() platform.Clipboard { return clipboard{} }
