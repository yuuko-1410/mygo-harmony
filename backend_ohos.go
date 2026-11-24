//go:build openharmony

package mygo

import (
	"github.com/egoist/mygo/internal/ohos"
	"github.com/egoist/mygo/internal/platform"
)

func newBackend() platform.Backend { return ohos.New() }
