# MyGo on OpenHarmony (HarmonyOS)

Status of the port in this tree, and what the platform layer has to provide.

## Shape

A HarmonyOS app is an ArkTS UIAbility. MyGo runs as a native library inside
it: Go is built as a `c-archive` and linked into a small C++ NAPI module the
XComponent loads, and MyGo's loop draws native UI into the XComponent's
`OHNativeWindow` over EGL/GLES3.

```
app.ets ── XComponent(libraryname: 'entry')
             │  loads libentry.so, hands it the OHNativeXComponent
             ▼
        libentry.so (napi_init.cpp)
             │  OnSurfaceCreated → mygo_surface_created(OHNativeWindow*, w, h, density)
             │  DispatchTouchEvent → mygo_touch(phase, id, x, y, pressure)
             │  OnFrame → mygo_frame()
             ▼
        libapp.a (Go: package main + internal/ohos)
             internal/ohos/backend.go    platform.Backend: loop, frames, windows
             internal/ohos/surface.go    Surface over OHNativeWindow → gl.NewWindow
             internal/ohos/window.go     Window (60 methods, the rest inert)
             internal/ohos/api.go        the //export boundary above
             internal/ohos/vsync.go      frame interval (XComponent onFrame)
             internal/ohos/ime.go        text input, both directions
             internal/text/engine_openharmony.go  system text over libnative_drawing
```

## Toolchain

`GOOS=openharmony` comes from the `sysit/ohos-go` fork of `golang/go`
(`openharmony/arm64`, musl, PIE by default, `c-shared`/`c-archive`).
Build it once on the machine with its own Go 1.24.6+:

```sh
git clone https://github.com/sysit/ohos-go
cd ohos-go/src && GOTOOLCHAIN=local CGO_ENABLED=0 GOROOT_BOOTSTRAP=$(go env GOROOT) ./make.bash
```

Two patches are needed when the *host* is not one of the fork's release
hosts (this machine is HarmonyOS aarch64, its Go reports `linux/arm64`):

1. `*_openharmony.go`/`.s` files carry no build tag; a stock bootstrap Go
   does not know the `_openharmony` filename suffix and compiles them
   alongside the linux ones. Add `//go:build openharmony`.
2. `/storage` (hmfs) fails `fallocate` with `EACCES`, which Go's linker
   tolerates only for `EPERM`/`ENOTSUP`. Tolerate `EACCES` too in
   `src/cmd/link/internal/ld/outbuf_mmap.go`.

## Platform API map

| MyGo needs | Android | iOS | OpenHarmony (this port) |
|---|---|---|---|
| surface | `ANativeWindow*` | `CAMetalLayer` | `OHNativeWindow*` from XComponent ✅ |
| GPU | EGL + GLES3 | Metal | EGL + GLES3 (`gl/egl_openharmony.go`) ✅ |
| frames | `Choreographer` | `CADisplayLink` | `OH_NativeXComponent_RegisterOnFrameCallback` ✅ |
| occlusion | surface callbacks | `scenePhase` | SurfaceShow/Hide callbacks ✅ |
| text | `Paint`/`Typeface` via the host | CoreText | `libnative_drawing` ✅ |
| IME | `InputConnection` | `UITextInput` | `napi_threadsafe_function` + ArkTS ✅ |
| images | `BitmapFactory` | ImageIO | `libimage_source` ⬜ |
| external textures | `SurfaceTexture` | `CVPixelBuffer` | `OH_NativeImage` ⬜ |
| wide gamut | `ColorSpace` | `CGColorSpace` | `OH_NativeColorSpaceManager` ⬜ |
| damage present | `Surface` damage | `presentsWithTransaction` | `OH_NativeWindow` FlushBuffer ⬜ |
| menus/dialogs/notifications | Kotlin host | Swift host | ArkTS over NAPI ✅ (dialogs, notifications) |
| accessibility | `AccessibilityNodeProvider` | `UIAccessibility` | ArkUI nodes ⬜ |

## Text engine

`internal/text/engine_openharmony.go` implements `engine` over
`libnative_drawing`:

- `OH_Drawing_FontMgrMatchFamilyStyle` for families, falling back to the
  system font;
- `OH_Drawing_FontTextToGlyphs` + `OH_Drawing_FontGetWidths` for shaping and
  advances (DIPs), `OH_Drawing_FontGetMetrics` for ascent/descent/leading;
- `OH_Drawing_FontGetPathForGlyph` + `OH_Drawing_PathGetBounds` for the ink
  box, and a canvas over an `ALPHA_8` bitmap to rasterize coverage;
- greedy line breaking at spaces, underline/strikethrough from the font's
  size, `register` of app fonts through `OH_Drawing_TypefaceCreateFromFile`,
  `systemFamilies` through `OH_Drawing_FontMgrGetFamilyName`.

Two constants matter: `COLOR_FORMAT_ALPHA_8` is **1** and
`ALPHA_FORMAT_PREMUL` is **2**. Getting them wrong still produces a bitmap,
just a sheared, half-width one — the "text looks broken" bug of the port.

`internal/text/debug` helpers (`debugMeasure`, `debugDumpGlyph`, `logLines`)
log measured numbers and an ASCII picture of a glyph; they turned the last
text bug from guesswork into a five-minute fix.

## Building an app

The tool does it (`cmd/mygo/ohos.go`):

```sh
go build -o mygo ./cmd/mygo

mygo ohos doctor            # the Go toolchain, the SDK, devecocli, a device
mygo ohos build <app dir>   # libapp.a, then the HAP
mygo ohos run <app dir>     # and install it, and start it
```

`-hap` says which HAP project to build; without it the tool takes the one
next to the app (a directory holding `entry/src/main/cpp/CMakeLists.txt`).
`-go` and `-sdk` override the toolchain, as `$OHOS_GO` and `$OHOS_SDK` do.

The app is any MyGo program: its own `go.mod` depending on this fork of
MyGo, a `main()` that calls `mygo.App.Run()`, and nothing OpenHarmony
specific in it. The tool cross-compiles it to `libapp.a`
(`-buildmode=c-archive`) and puts it where the HAP's CMake links it.

## Porting another app

The native shell is the same for every app: NAPI entry, XComponents, the
IME overlay, the host-call channel, the subwindow page. It ships inside the
tool (`cmd/mygo/shell`), which writes it out and names it:

```sh
mygo ohos init -hap ~/apps/notes-ohos -bundle com.example.notes -label Notes ~/apps/notes
cd ~/apps/notes-ohos && devecocli signature generate   # once per bundle
mygo ohos run ~/apps/notes
```

What the shell expects of the app, and of the toolchain:

| Piece | Where | Notes |
|---|---|---|
| MyGo with this backend | the app's `replace`/`require` | `backend_ohos.go` registers `internal/ohos` for `GOOS=openharmony` |
| Go toolchain | `$OHOS_GO`, default `~/Documents/MyProjects/ohos-go/bin/go` | a Go whose `dist list` has `openharmony/arm64` (see Toolchain) |
| Native SDK | `$OHOS_SDK`, the DevEco `ohos-sdk-native` cell | clang, sysroot, `llvm-ar` |
| HAP signing | `devecocli signature generate` once per bundle | `mygo ohos run` calls `devecocli run` |

The app's `main()` may use every MyGo API; what differs by platform is
what `internal/ohos` implements (below). Nothing in the app's code names
OpenHarmony.

The HAP project needs `externalNativeOptions` pointing at its `CMakeLists.txt`,
which links `libapp.a` and `libace_napi.z`, `libace_ndk.z`, `libnative_window`,
`libnative_drawing`, `libnative_vsync`, `libEGL`, `libGLESv3`.

## Where this fork differs from upstream MyGo

Everything is additive; the only edits to existing files are build tags, so
that upstream's Linux/X11 and Pango code does not claim `openharmony`:

```
backend_linux.go, backend_other.go, content_rules_other.go,
context_menu_other.go, dmabuf_other.go, menuicon_other.go,
notification_image_other.go, nowplaying_other.go,
internal/gpu/gl/{gl,load_linux,offscreen,present,read,swap_linux}.go,
internal/text/{engine_other,pango_linux}.go,
ui/gpu_linux.go, ui/gpu_other.go
        build tag gains `&& !openharmony` (linux) or `&& !openharmony`
```

and these files are new:

```
backend_ohos.go                     newBackend() for GOOS=openharmony
internal/ohos/                      the backend: event loop, windows,
                                    surfaces, input, IME, host calls,
                                    clipboard, dialogs, notifications,
                                    shell, screen, theme, device form
internal/gpu/gl/egl_openharmony.go  EGL on OHNativeWindow
internal/gpu/gl/load_openharmony.go GLES loader
internal/text/drawing_ohos.go       libnative_drawing bindings (purego)
internal/text/engine_openharmony.go FontMgr/TextShaper/Path rendering
ui/gpu_openharmony.go               the GPU renderer for this platform
cmd/mygo/ohos.go                    mygo ohos: build, run, init, doctor
cmd/mygo/ohos_init.go               the shell of a HAP, written out
cmd/mygo/shell/                     that shell: ArkTS pages, NAPI, CMake
```

## Not done yet

Done and verified on a 2in1: window/surface lifecycle, GPU rendering,
text (shaping, wrapping, paths), touch/mouse/keyboard input, IME (two-way),
scroll (wheel and finger, with momentum), clipboard, dialogs, file pickers,
notifications, shell open, screen info, theme, several OS windows with
their own surfaces, and closing them from either side.

| Missing | Where it would go |
|---|---|
| Cursor shapes (`Surface.SetCursor`) | `@ohos.multimodalInput.pointer.setPointerStyle` |
| Window size/position back from the OS | `windowSizeChange` → `mygo_window_bounds(id, …)`; `Bounds()` is still the requested rect |
| Window options (fullscreen, maximize, opacity, corner radius, always-on-top, min/max size) | `setWindowLimits`, `maximize`, `setWindowDecorVisible`, `setWindowKeepScreenOn` |
| Menus (menu bar, context menus) | ArkTS `Menu`/`bindMenu` over the host-call channel |
| Accessibility tree | `AccessibilityExtension` or `accessibilityLevel/text` per node |
| Drag and drop, web views | ArkUI `onDragStart`/`onDrop`, the `Web` component overlaid as the IME is |
| Page capture, print to PDF | `componentSnapshot`, `@ohos.print` |
| External textures (video, camera) | `OH_NativeImage` → `plugins/video` |
| Wide gamut / HDR | `OH_NativeColorSpaceManager`, BT2020 HLG/PQ |
| Phone navigation (tabs, push/pop) | `platform.NavigationBackend` over ArkTS `Tabs`/`Navigation`; the form factor already tells phones from desktops (`internal/ohos/device.go`) |
| Vulkan renderer | optional, mirroring Metal on iOS |

## Host calls

What only ArkTS can do reaches it through a request/reply channel: Go
sends `{id, op, args}` as JSON through `napi_threadsafe_function`
(`mygo_host_call`), ArkTS answers `{id, result}` or `{id, error}` through
`native.hostReply`, and `internal/ohos/rpc.go` matches the answer to the
goroutine waiting for it.

Implemented operations:

| op | ArkTS | Verified |
|---|---|---|
| `clipboard.read` / `clipboard.write` | `pasteboard` | ✅ channel, empty text without the user's gesture |
| `dialog.message` | `promptAction.showDialog` | ✅ both buttons return their index |
| `notification.show` / `.remove` / `.clear` | `notificationManager` | ✅ published |

The same channel is the place for file pickers, menus and the accessibility
tree.

## Several windows

Each MyGo window is one XComponent. The host keeps the first XComponent
mounted, full size, and a second one at 1×1 that grows when MyGo asks for
another window:

```
Go NewWindow ──host call "window.create" {id}──▶ ArkTS shows mygo<id>
     ▲                                              │
     └── mygo_surface_created_id(id, OHNativeWindow) ◀┘ OnSurfaceCreated
```

`OH_NativeXComponent_GetXComponentId` names each component (`mygo`,
`mygo1`, …), and its digits are the window's id: resize events
(`mygo_surface_resized_id`) and surface callbacks carry it, so a window is
resized without touching the others. Dynamic `ForEach` mounting of an
XComponent proved unreliable in ArkTS; a resident component resized by
state is what works.

## Colour and lifecycle

`OnSurfaceCreated` sets the window's colour space to `OH_COLORSPACE_BT709_FULL`
(reading it back reports 3) instead of leaving it to the compositor. Surface
show/hide callbacks drive both frame pausing and `AppHandler.DidBecomeActive`
/ `DidResignActive`.
