//go:build openharmony

package mobile

/*
#cgo LDFLAGS: -lhilog_ndk.z
#include <stdint.h>
#include <stdlib.h>

void mygo_ohos_call(uint8_t *msg, size_t len, uint8_t **reply, size_t *reply_len);
void mygo_ohos_post(void);
*/
import "C"

import (
	"syscall"
	"unsafe"
)

// cHost is the ArkTS host, through the NAPI module's C side
// (openharmony/entry/src/main/cpp/napi_init.cpp). Its call runs on the JS
// thread, which is this platform's UI thread: the transport hands it calls
// only there, when ArkTS drains them (mygo_drain).
type cHost struct{}

func (cHost) call(msg []byte) []byte {
	var reply *C.uint8_t
	var n C.size_t
	C.mygo_ohos_call((*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(msg))), C.size_t(len(msg)), &reply, &n)
	if reply == nil {
		return nil
	}
	b := C.GoBytes(unsafe.Pointer(reply), C.int(n))
	C.free(unsafe.Pointer(reply))
	return b
}

// callHere is call: the host's calls all run on the JS thread, which is this
// platform's UI thread, so a thread that must not wait for the UI thread —
// the sound's — waits for the next drain instead of jumping the queue.
func (cHost) callHere(msg []byte) []byte { return cHost{}.call(msg) }

func (cHost) post() { C.mygo_ohos_post() }

// onUIThread reports whether this is the thread the host's views live on:
// the process's main thread, on which ArkTS runs.
func onUIThread() bool { return syscall.Gettid() == syscall.Getpid() }

//export mygo_start_ohos
func mygo_start_ohos() {
	theHost = cHost{}
	start()
}

//export mygo_event
func mygo_event(msg *C.uint8_t, n C.size_t, onUI C.int, reply **C.uint8_t, replyLen *C.size_t) {
	r := deliver(unsafe.Slice((*byte)(unsafe.Pointer(msg)), int(n)), onUI != 0)
	*reply, *replyLen = nil, 0
	if r != nil {
		p := C.malloc(C.size_t(max(len(r), 1)))
		copy(unsafe.Slice((*byte)(p), len(r)), r)
		*reply, *replyLen = (*C.uint8_t)(p), C.size_t(len(r))
	}
}

//export mygo_drain
func mygo_drain() { drain() }
