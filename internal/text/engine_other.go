//go:build !openharmony && !(windows && (amd64 || arm64)) && !darwin && !(linux && !openharmony && !android && (amd64 || arm64)) && !js && !android

package text

func newEngine() engine { return &stubEngine{} }
