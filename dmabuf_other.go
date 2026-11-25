//go:build (!(linux && !android && (amd64 || arm64)) || openharmony) || ohos

package mygo

func linkDMABUFProbe() {}
