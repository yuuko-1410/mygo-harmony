//go:build openharmony

package gl

// OpenHarmony has no GTK area and no GLX swap: the X11 backend builds here
// as dead code (nothing on this platform imports it), so that every package
// of the tree builds for every platform its toolchain lists.
func MakeAreaCurrent(uintptr) bool { return false }

func UnsyncGLXSwaps() {}
