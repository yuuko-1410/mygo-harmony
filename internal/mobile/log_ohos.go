//go:build openharmony

package mobile

/*
#include <stdint.h>
#include <stdlib.h>

void mygo_ohos_log(int error, uint8_t *line, size_t len);
*/
import "C"

import (
	"os"
	"runtime/debug"
	"syscall"
	"unsafe"
)

// hostLog shows a line of the app's output in the system log, where the
// device shows nothing of a process's standard output.
func hostLog(isErr bool, line []byte) {
	e := C.int(0)
	if isErr {
		e = 1
	}
	C.mygo_ohos_log(e, (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(line))), C.size_t(len(line)))
}

// dupOutput makes the descriptor of old write to w, for the runtime's own
// writes (panics) to go to the log too.
func dupOutput(w, old *os.File) error {
	return syscall.Dup3(int(w.Fd()), int(old.Fd()), 0)
}

// keepCrashOutput has the runtime report a crash, all of it, before the app
// goes: the report of a panic that ends an app would otherwise be written to
// the pipe redirectOutput makes, which nothing reads once the runtime exits.
// The descriptor the system gave the app takes it whole, as it exits.
func keepCrashOutput() {
	debug.SetTraceback("all")
	if fd, err := syscall.Dup(2); err == nil {
		f := os.NewFile(uintptr(fd), "stderr")
		debug.SetCrashOutput(f, debug.CrashOptions{})
		f.Close()
	}
}
