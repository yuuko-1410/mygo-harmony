//go:build (!(darwin && !ios) && !(linux && !android && (amd64 || arm64)) && !(windows && (amd64 || arm64)) || openharmony) || ohos

package mygo

func linkContextMenus() {}
