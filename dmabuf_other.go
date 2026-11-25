//go:build !(linux && !openharmony && !android && (amd64 || arm64))

package mygo

func linkDMABUFProbe() {}
