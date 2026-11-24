//go:build openharmony

package ohos

/*
#include <stdint.h>
typedef void *OH_NativeVSyncHandle;
OH_NativeVSyncHandle OH_NativeVSync_Create(const char *name, unsigned int length);
int OH_NativeVSync_GetPeriod(OH_NativeVSyncHandle vsync, long long *period);
void OH_NativeVSync_Destroy(OH_NativeVSyncHandle vsync);
*/
import "C"

import (
	"log"
	"sync"
	"time"
	"unsafe"
)

var (
	vsyncOnce   sync.Once
	vsyncHandle C.OH_NativeVSyncHandle
	vsyncEvery  time.Duration = 16 * time.Millisecond
)

// frameInterval returns the display's refresh interval through
// OH_NativeVSync, falling back to 16ms when the system does not tell it.
func frameInterval() time.Duration {
	vsyncOnce.Do(func() {
		name := []byte("mygo")
		vsyncHandle = C.OH_NativeVSync_Create((*C.char)(unsafe.Pointer(&name[0])), C.uint(len(name)))
		if vsyncHandle == nil {
			log.Printf("ohos: no vsync handle; pacing at %v", vsyncEvery)
			return
		}
		var ns C.longlong
		if rc := C.OH_NativeVSync_GetPeriod(vsyncHandle, &ns); rc != 0 || ns <= 0 {
			log.Printf("ohos: vsync period unavailable (rc=%d); pacing at %v", int(rc), vsyncEvery)
			return
		}
		vsyncEvery = time.Duration(ns)
		log.Printf("ohos: display refresh %v (%.1f Hz)", vsyncEvery, float64(time.Second)/float64(vsyncEvery))
	})
	return vsyncEvery
}
