//go:build openharmony || (linux && ohos)

package ohos

/*
#include <stdint.h>
void mygo_host_textinput(char *json);
*/
import "C"

import (
	jsonpkg "encoding/json"
	"unsafe"

	"github.com/egoist/mygo/internal/platform"
)

// textInputJSON is what the ArkTS host gets when an editable element takes
// or leaves the keyboard.
type textInputJSON struct {
	On     bool    `json:"on"`
	Text   string  `json:"text"`
	Start  int     `json:"start"`
	End    int     `json:"end"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"w"`
	Height float64 `json:"h"`
}

// setTextInput tells the host that an editable element took the keyboard,
// where its caret is and the text around it, or that it left.
func (s *surface) SetTextInput(t platform.TextInputState) {
	state := textInputJSON{
		On:     t.Active,
		Text:   t.Text,
		Start:  t.Start,
		End:    t.End,
		X:      t.Caret.X,
		Y:      t.Caret.Y,
		Width:  t.Caret.W,
		Height: t.Caret.H,
	}
	data, err := jsonpkg.Marshal(state)
	if err != nil {
		return
	}
	buf := append(data, 0)
	C.mygo_host_textinput((*C.char)(unsafe.Pointer(&buf[0])))
}

// textInputEvent is what the host sends when the input method composes or
// the user types.
type textInputEvent struct {
	Text      string `json:"text"`
	Composing bool   `json:"composing"`
	From      int    `json:"from"`
	To        int    `json:"to"`
}

//export mygo_text_input
func mygo_text_input(jsonPtr *C.char) {
	if jsonPtr == nil {
		return
	}
	var in textInputEvent
	if err := jsonpkg.Unmarshal([]byte(C.GoString(jsonPtr)), &in); err != nil {
		return
	}
	b := current()
	if b == nil {
		return
	}
	ev := platform.SurfaceEvent{
		Kind:    platform.TextInput,
		Text:    in.Text,
		From:    in.From,
		To:      in.To,
		Replace: in.Composing,
	}
	b.push(func() { b.deliver(ev) })
}
