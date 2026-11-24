package ohos

import (
	"net/url"

	"github.com/egoist/mygo/internal/platform"
	"github.com/egoist/mygo/internal/unsupported"
)

// shell hands links and files to the system: ArkTS starts the ability that
// opens them.
type shell struct{ unsupported.Shell }

func (shell) OpenExternal(link string) error {
	_, err := callHost("shell.open", map[string]string{"uri": link})
	return err
}

func (shell) OpenPath(path string) error {
	_, err := callHost("shell.open", map[string]string{"uri": "file://" + url.PathEscape(path)})
	return err
}

func (shell) ShowItemInFolder(path string) {
	_, _ = callHost("shell.showInFolder", map[string]string{"path": path})
}

func (b *backend) Shell() platform.Shell { return shell{} }
