//go:build !(windows && (amd64 || arm64)) && !darwin && !(linux && !android && (amd64 || arm64)) && !js && !android && !openharmony

package text

func newEngine() engine { return &stubEngine{} }
