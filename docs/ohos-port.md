# OpenHarmony (HarmonyOS)

MyGo builds for OpenHarmony as a HAP: the app compiles to a c-archive, and a
shell of ArkTS and C++ loads it into the window it shows. The shell is the
phone backend's own — `internal/mobile`, with the ArkTS host of
`internal/mobile/openharmony` behind the messages of
`internal/mobile/wire` — so an app is plain MyGo, with nothing of the platform
in its code.

What a host must do, and what this platform makes of it, is written at the
bottom of `internal/mobile/openharmony/README.md` and in
`internal/mobile/openharmony/NOTES.md`.

Status of the port in this tree, and what the platform layer has to provide.

## This tree is a fork

`mygo-harmony` is a fork of `egoist/mygo` that adds this port, and has two
branches:

- `main` mirrors `upstream/main` and takes no commit of ours of its own.
- `ohos-port` carries the port, rebased onto `main`.

```sh
sh scripts/sync-upstream.sh
```

does the whole round: fetch `upstream`, fast-forward `main` here and on the
fork, rebase `ohos-port`, push it with `--force-with-lease`. It never checks
`main` out, so a script that lives on `ohos-port` alone survives its own run.
Turn `git config --global rerere.enabled true` on first: upstream's edits to
`ui/gpu_*.go` and `cmd/mygo/*.go` come back around, and it resolves them the
second time alone.

Keep what the port does to files upstream owns as small as it is. Everything
in a file of its own (`internal/ohos/`, `*_openharmony.go`) costs a rebase
nothing; every hunk of a file upstream also edits is a conflict later.

The module path stays `github.com/egoist/mygo` in `ohos-port`'s own commits,
so they replay onto upstream without dragging 1479 rewritten files through
every rebase. A release that needs the fork's path gets it in one commit kept
at the tip, regenerated after each rebase:

```sh
git commit --allow-empty -m "harmony: rename the module"   # once
sh scripts/harmony-module.sh                              # after each rebase
```

It is also the one commit to drop when sending a patch upstream: what sits
under it is already typed against upstream's own path. Tag a release at the
tip, `v0.10.0-ohos.1`, so `go install …/cmd/mygo@v0.10.0-ohos.1` reads the
renamed module.

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

The patches live in `tools/ohos-go/` (`ohos-go.patch`, applied once per
checkout). `mygo ohos doctor` tells whether the tree it found has them.

A more thorough port exists: `ZxillyFork/go-hmos` (a fork of `golang/go`,
branch `hmos-release-branch.go1.27`, `VERSION` `go1.27.4-hmos-devel`). It has
what the fork above lacks — `runtime/sigtab_openharmony.go`, which keeps
OHOS's own `SIGURG`/`SIGPROF` instead of repurposing them as Go does on Linux;
`runtime/cgo/gcc_openharmony.c` with its callbacks; `net/dnsconfig_openharmony.go`;
`internal/cpu/cpu_arm64_openharmony.go`; and tests of the platform. Switching
to it changes nothing here: the same GOOS, the same `-buildmode=c-archive`.
It was not adopted yet because it publishes only a linux-amd64 binary, so an
arm64 host must bootstrap it from source, and on this machine newly built tool
binaries are refused by `execve` (`EACCES`) outside a plain terminal.


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

The tool does it (`cmd/mygo/ohos.go`, `cmd/mygo/ohos_init.go`):

```sh
go build -o mygo ./cmd/mygo

mygo doctor                      # says whether the toolchain is there
mygo build -platform ohos        # a signed .hap in dist/ohos
mygo dev -platform ohos          # installs it, runs it, follows its log
mygo ohos run <app dir>          # the same, without a watched session
mygo ohos init -hap <dir> ...    # a HAP project of its own, to keep
```

The HAP project is generated, as Android's Gradle project is: `mygo build`
writes it into `<app>/.mygo/ohos`, and `mygo dev` into
`<app>/.mygo/dev/ohos/project`, from the shell the tool carries
(`cmd/mygo/shell`). Nothing of it is checked in. `-hap` builds in a project
of your own instead, such as the `mygo-ohos` this port was made with.

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
