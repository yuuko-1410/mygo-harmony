# OpenHarmony host

The ArkTS host of `internal/mobile`: the second host of the phone backend,
next to Kotlin (`../android`) and Swift (`../ios`), on the same messages of
`../wire`. Go is the app, built as a c-archive and linked into `libentry.so`
here, and the host is the window, the surface, input and the system's dialogs.

```
entry/src/main/
  cpp/napi_init.cpp   the NAPI module `entry`: starts Go, carries the messages,
                      registers the XComponent's callbacks
  cpp/CMakeLists.txt  links libapp.a (the app's c-archive) into libentry.so
  ets/mygo/Wire.ets       generated: the codec and the 150 messages
  ets/mygo/HostStubs.ets  generated: every call, unimplemented
  ets/mygo/Host.ets       the calls this host answers, over HostStubs
  ets/pages/Index.ets     the XComponent, its touch, and frames
```

`Wire.ets` and `HostStubs.ets` are written by `go generate ./internal/mobile/wire`
from `spec.go`, as `Wire.kt` and `Wire.swift` are; do not edit them.

## Building

```sh
SDK=~/.harmonybrew/Cellar/ohos-sdk-native/<version>
export GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1
export CC="$SDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$SDK/sysroot -D__MUSL__"
export AR="$SDK/llvm/bin/llvm-ar"
go build -buildmode=c-archive -o entry/src/main/cpp/libapp.a <the app>
```

then `hvigorw assembleHap` (or `devecocli build`) in the app's project, whose
`entry/src/main/cpp` is this directory and whose `module.json5` lists
`pages/Index` first.

## Why the window was black

`surface.Native()` asked `mapsSchemes` — `runtime.GOOS == "android"` — whether
the handle is the system's window or a layer to make one of, because on
Android both are true. OpenHarmony is not a GOOS here but a tag: the toolchain
says `linux`, so `runtime.GOOS` is `linux`, the answer was "layer", and `ui`
made no renderer at all. `nativeWindow` (in `window.go`) is the question that
should have been asked, and `openharmony` (in `ohos.go`) is how a build knows
it is this platform when the GOOS cannot say so.

## Chinese draws because of the font files

The platform's font manager knows ten families — HarmonyOS-Sans at its weights,
serif, monospace, notdef — and none of them has a Han character:
`OH_Drawing_FontTextToGlyphs` maps 「中」 to nothing, and
`OH_Drawing_FontMgrMatchFamilyStyleCharacter`, the call meant for exactly
this, hands back a typeface without it. `HarmonyOS_Sans_SC.ttf` in
`/system/fonts` has it, and `OH_Drawing_TypefaceCreateFromFile` opens it. So
the engine asks the manager's per-character match first, then the files, and
takes the first typeface that really maps the rune (a check, not a hope).

## The protocol's two rules, learned the hard way

- **Do not send `Ready`.** The backend posts it itself (`postReady`), before
  what the host sent; a second one closes `App.readyCh` twice and Go aborts
  with `close of closed channel`, before any of its output reaches the log.
- **Pass a `Uint8Array`, not the `ArrayBuffer` it lies on.** `WireReader`
  reads `buf.length` and indexes it: an ArrayBuffer gives `undefined`, every
  call decodes as op 0, and every reply is nil.

## What is done

- the Go side: `glue_ohos.go` (cgo, the `mygo_ohos_*` entry points), and the
  build tags that make `internal/mobile` the backend of `GOOS=openharmony`
  (`backend_mobile.go`, `backend_other.go`, `backend_linux.go`,
  `internal/mobile/native.go`, `timezone_phone.go`, `log_ohos.go`, and the
  desktop-only `_other.go` stubs that openharmony now reaches);
- the codec, written for ArkTS's numbers: `WireWriter`/`WireReader` write the
  varint with division rather than shifts, since ArkTS's bit operators are 32
  bits wide, and UTF-8 by hand rather than with `@ohos.util`;
- the shim: `start`, `event` and `drain`, the XComponent's surface and touch
  callbacks, a threadsafe function for `post`, and the app's log lines;
- touch: a surface's fingers arrive in the XComponent's own
  `DispatchTouchEvent`, not in ArkUI's `onTouch` (the surface is the app's),
  in pixels, which the host divides by the scale to reach DIPs;
- a host that makes a window, reports its surface and its size, paints the
  background Go asks for, sends `Frame` at the display's refreshes (and at
  the rate `SetFrameRate` asks), forwards touch, and answers the calls a
  start needs;
- the keyboard: `SetTextInput` places a see-through `TextInput` over what Go
  draws, focuses it, and the keys it takes go back as `TextReplace` and
  `TextCommand` — a field is typed in, and what Go draws says what it holds;
- the insets of `Resized`, read from the window's avoid areas
  (`TYPE_SYSTEM`, `TYPE_CUTOUT`, `TYPE_KEYBOARD`) and sent again as they
  change.

Verified on the device (MateBook Pro S, API 26): the app's c-archive builds
(32.4 MB), `libentry.so` links, and the HAP builds, installs and launches.

On the device the window shows what the app draws — a block and a line of
text, in the first frame — and Go's own calls arrive: `AppInfo`,
`Theme`, `CreateWindow` (14 KB of schemes and scripts), `ShowWindow`,
`SetBackground`, and `FirstFrame` — the content drew, and the host showed
what it drew. Text comes from `internal/text`'s OpenHarmony engine, which
reaches `libnative_drawing` through purego, so there is no pango to miss.

## What is not

The insets are the window's own — zero in a floating window, which is what
the 2in1 gives — and whether the core moves a plain window's content by them
is untested: there is no keyboard and no full-screen bar here to move it.
The host logs what the field gives it (`mygo: field`, `mygo: compose`,
`mygo: replace`, under `A03D00/.../JSAPP`): with the log, typing in the field
says whether the input method composed or committed.

An input method's composing text goes as `TextMark`, and its commit replaces
the marked text (`TextReplace` with no range), which is what the protocol
describes. The field's own text and caret are transparent: the app draws
both, the field only takes the keys. Not yet: selection, `TextDelete` for
backspace, and the arrow commands — and the composing text is untested,
since the harness that types here commits text instead of composing. Nothing draws in a window's child
views (`PlaceViews`), and there is no web view, no tabs, no accessibility
tree.

The host answers a window, a surface, frames and touch. Everything else — the
keyboard, the web view, tabs, accessibility, insets, the services — is
`HostStubs` for now, which logs and does nothing; the calls exist in
`Wire.ets` already, so each is a method of `Host.ets` away.
