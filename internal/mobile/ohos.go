//go:build openharmony

package mobile

// openharmony is whether this build is OpenHarmony's. It is a tag, not a
// GOOS: the toolchain that builds it says linux, so that the standard
// library's syscalls and files are the ones the kernel has, and the
// platform's own differences are behind build tags.
const openharmony = true
