//go:build !(linux && !android && (amd64 || arm64)) || openharmony

package mygo

func linkDMABUFProbe() {}
