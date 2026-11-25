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

## What is done

- the Go side: `glue_ohos.go` (cgo, the `mygo_ohos_*` entry points), and the
  build tags that make `internal/mobile` the backend of `GOOS=openharmony`
  (`backend_mobile.go`, `backend_other.go`, `backend_linux.go`,
  `internal/mobile/native.go`, `timezone_phone.go`, `log_ohos.go`, and the
  desktop-only `_other.go` stubs that openharmony now reaches);
- the codec, written for ArkTS's numbers: `WireWriter`/`WireReader` write the
  varint with division rather than shifts, since ArkTS's bit operators are 32
  bits wide, and UTF-8 by hand rather than with `@ohos.util`;
- the shim: `start`, `event` and `drain`, the XComponent's surface callbacks,
  a threadsafe function for `post`, and the app's log lines;
- a host that makes a window, reports its surface, sends `Frame` at the
  display's refreshes, forwards touch, and answers the calls a start needs.

Verified on the device (MateBook Pro S, API 26): the app's c-archive builds
(32.4 MB), `libentry.so` links, and the HAP builds, installs and launches.

## What is not

The app aborts (SIGABRT) within a second of launch, before any line of Go
reaches the log, so the shim or the archive's constructor is the suspect and
not the host's answers. `MYGO init` does not print: either the module's `Init`
is not reached, or the abort comes before it, from the c-archive's own
`DT_INIT_ARRAY` constructor — the case CL 696635 (#13492) describes, where Go
reads `argc`/`argv` a non-glibc loader never passed. That is the next thing to
determine, by a `dlopen` of the same archive from a library that does load.

The host answers a window, a surface, frames and touch. Everything else — the
keyboard, the web view, tabs, accessibility, insets, the services — is
`HostStubs` for now, which logs and does nothing; the calls exist in `Wire.ets`
already, so each is a method of `Host.ets` away.
