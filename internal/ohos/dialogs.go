//go:build openharmony || (linux && ohos)

package ohos

import (
	"encoding/json"

	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/internal/unsupported"
)

// dialogs shows the platform's dialogs through the host: ArkTS's
// promptAction draws them, and the answer comes back on the main thread as
// the platform's callbacks must.
type dialogs struct{ unsupported.Dialogs }

type messageArgs struct {
	Title    string   `json:"title"`
	Message  string   `json:"message"`
	Detail   string   `json:"detail,omitempty"`
	Buttons  []string `json:"buttons,omitempty"`
	Default  int      `json:"default"`
	Cancel   int      `json:"cancel"`
	Kind     string   `json:"kind,omitempty"`
	Checkbox string   `json:"checkbox,omitempty"`
}

func (d *dialogs) ShowMessageBox(parent platform.Window, opts *platform.MessageBoxOptions, cb func(platform.MessageBoxResult, error)) {
	args := messageArgs{
		Title:    opts.Title,
		Message:  opts.Message,
		Detail:   opts.Detail,
		Buttons:  opts.Buttons,
		Default:  opts.DefaultID,
		Cancel:   opts.CancelID,
		Kind:     opts.Type,
		Checkbox: opts.CheckboxLabel,
	}
	b := currentOrNil()
	go func() {
		raw, err := callHost("dialog.message", args)
		result := platform.MessageBoxResult{Response: opts.CancelID}
		if err == nil && len(raw) > 0 {
			var out struct {
				Response int  `json:"response"`
				Checked  bool `json:"checked"`
			}
			if json.Unmarshal(raw, &out) == nil {
				result = platform.MessageBoxResult{Response: out.Response, CheckboxChecked: out.Checked}
			}
		}
		done := func() { cb(result, err) }
		if b != nil {
			b.push(done)
			return
		}
		done()
	}()
}

func currentOrNil() *backend { return current() }

func (b *backend) Dialogs() platform.Dialogs { return &dialogs{} }

type openArgs struct {
	Title    string   `json:"title"`
	Multiple bool     `json:"multiple"`
	Dir      bool     `json:"dir"`
	Types    []string `json:"types,omitempty"`
}

func (d *dialogs) ShowOpenDialog(parent platform.Window, opts *platform.OpenDialogOptions, cb func([]string, error)) {
	args := openArgs{Title: opts.Title, Multiple: opts.Multiple, Dir: opts.OpenDirectories}
	for _, f := range opts.Filters {
		args.Types = append(args.Types, f.Extensions...)
	}
	b := current()
	go func() {
		raw, err := callHost("dialog.open", args)
		var paths []string
		if err == nil && len(raw) > 0 {
			var out struct {
				Paths []string `json:"paths"`
			}
			if json.Unmarshal(raw, &out) == nil {
				paths = out.Paths
			}
		}
		done := func() { cb(paths, err) }
		if b != nil {
			b.push(done)
			return
		}
		done()
	}()
}

type saveArgs struct {
	Title string `json:"title"`
	Name  string `json:"name"`
}

func (d *dialogs) ShowSaveDialog(parent platform.Window, opts *platform.SaveDialogOptions, cb func(string, error)) {
	args := saveArgs{Title: opts.Title, Name: opts.DefaultPath}
	b := current()
	go func() {
		raw, err := callHost("dialog.save", args)
		path := ""
		if err == nil && len(raw) > 0 {
			var out struct {
				Path string `json:"path"`
			}
			if json.Unmarshal(raw, &out) == nil {
				path = out.Path
			}
		}
		done := func() { cb(path, err) }
		if b != nil {
			b.push(done)
			return
		}
		done()
	}()
}
