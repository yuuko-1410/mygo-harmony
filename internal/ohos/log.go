package ohos

/*
#include <stdint.h>
void mygo_log(int level, char *line, int len);
*/
import "C"

import (
	"bufio"
	"os"
	"syscall"
	"unsafe"
)

// redirectOutput sends what the app writes to its standard output and error
// to the system's log, where HarmonyOS shows nothing of them.
func redirectOutput() {
	for _, fd := range []int{1, 2} {
		r, w, err := os.Pipe()
		if err != nil {
			continue
		}
		if err := syscall.Dup3(int(w.Fd()), fd, 0); err != nil {
			r.Close()
			w.Close()
			continue
		}
		w.Close()
		level := 0
		if fd == 2 {
			level = 1
		}
		go func(r *os.File, level int) {
			s := bufio.NewScanner(r)
			s.Buffer(make([]byte, 4096), 1<<20)
			for s.Scan() {
				line := s.Bytes()
				if len(line) == 0 {
					continue
				}
				C.mygo_log(C.int(level), (*C.char)(unsafe.Pointer(&line[0])), C.int(len(line)))
			}
		}(r, level)
	}
}
