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

// dupOutput makes the descriptor of old write to w, for the app's own
// writes — the web view logs to the standard error too, thousands of lines
// of it — to reach the log.
//
// The pipe is non-blocking and as big as the system allows: a writer that
// finds it full gets an error and goes on, where a blocking pipe holds the
// thread that wrote still — the UI thread, in the middle of a gesture
// (PAC_LogMessage::Flush blocked in write()), which is a window that answers
// nothing.
func dupOutput(w, old *os.File) error {
	fd := int(w.Fd())
	// F_SETPIPE_SZ: 1031 on Linux, and on this one.
	syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), 1031, 1<<20)
	if err := syscall.SetNonblock(fd, true); err != nil {
		return err
	}
	return syscall.Dup3(fd, int(old.Fd()), 0)
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
