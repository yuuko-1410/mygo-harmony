package main

// A c-archive with the symbols the HAP's shell asks for, and nothing else:
// it answers whether a c-archive built by a stock Go loads as a NAPI module
// at all, separately from anything MyGo's backend does.

/*
#include <stdint.h>
*/
import "C"

//export mygo_start
func mygo_start(filesDir *C.char) {}

//export mygo_surface_created
func mygo_surface_created(native C.uintptr_t, width, height, scale C.double) {}

//export mygo_surface_created_id
func mygo_surface_created_id(id C.ulonglong, native C.uintptr_t, width, height, scale C.double) {}

//export mygo_surface_resized
func mygo_surface_resized(width, height, scale C.double) {}

//export mygo_surface_resized_id
func mygo_surface_resized_id(id C.ulonglong, width, height, scale C.double) {}

//export mygo_surface_destroyed
func mygo_surface_destroyed() {}

//export mygo_surface_shown
func mygo_surface_shown(shown C.int) {}

//export mygo_touch
func mygo_touch(phase, id C.int, x, y, pressure C.double) {}

//export mygo_mouse
func mygo_mouse(phase C.int, x, y C.double, button C.int) {}

//export mygo_key
func mygo_key(down, code C.int, text *C.char) {}

//export mygo_scroll
func mygo_scroll(dx, dy C.double) {}

//export mygo_scroll_at
func mygo_scroll_at(dx, dy, x, y C.double) {}

//export mygo_resize_id
func mygo_resize_id(id C.int, width, height, scale C.double) {}

//export mygo_frame
func mygo_frame() {}

//export mygo_quit
func mygo_quit() {}

//export mygo_text_input
func mygo_text_input(json *C.char) {}

//export mygo_host_reply
func mygo_host_reply(json *C.char) {}

//export mygo_window_closed
func mygo_window_closed(id C.int) {}

func main() {}
