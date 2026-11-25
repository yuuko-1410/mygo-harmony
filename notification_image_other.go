//go:build !(darwin && !ios) && !(linux && !openharmony && !android && (amd64 || arm64)) && !(windows && (amd64 || arm64))

package mygo

func linkNotificationImages() {}
