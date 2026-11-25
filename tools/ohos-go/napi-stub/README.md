# Does a stock Go's c-archive load as a NAPI module?

A c-archive of eighteen empty functions — the symbols the HAP's shell calls —
compiled two ways, linked into `libentry.so` by the same CMake, installed as
the same HAP:

```sh
SDK=${OHOS_SDK:-$HOME/.harmonybrew/Cellar/ohos-sdk-native/26.0.0.38}
CC="$SDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$SDK/sysroot -D__MUSL__"

# 1. a stock Go, as a linux c-archive
TMPDIR=/tmp GOCACHE=/tmp/gocache GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
  CC="$CC" AR=$SDK/llvm/bin/llvm-ar go build -buildmode=c-archive -o stub-stock.a .

# 2. the fork, whose GOOS is the platform's own
GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 \
  CC="$CC" AR=$SDK/llvm/bin/llvm-ar "$OHOS_GO" build -buildmode=c-archive -o stub-ohos.a .
```

| archive | `R_AARCH64_TLS_*` in `libentry.so` | `import native from 'libentry.so'` |
|---|---|---|
| stock Go | `1 × TLS_TPREL64` | `undefined`; the page throws, the app is killed |
| the fork | none | the module, its eighteen functions callable |

`-gcflags=all=-shared` and `-ldflags=-linkmode=external` leave the relocation
where it is. The difference is inside the toolchain: upstream Go has no way to
choose the TLS model of assembly (`cmd/asm` has no `-tls` flag), and this
c-archive's `runtime.tlsg` is assembled as initial-exec. ArkTS loads a NAPI
module with `dlopen`, where initial-exec TLS is not allowed; the fork adds
`-tls=GD` (`cmd/asm`, `cmd/internal/obj/arm64`, `cmd/go/internal/work`) so the
same symbol is assembled as general-dynamic.

`TMPDIR` matters on a HarmonyOS device: hmfs answers `EACCES` to `fallocate`,
which the unpatched linker takes for a fatal error.

## Reading the loader's refusal

`dlerror` is what names the cause, and a NAPI module cannot report its own
failure to load. Load it from one that does load — the fork's — by putting the
stub in the HAP as a second library and `dlopen`ing it there:

```cpp
// in napi_init.cpp's Init, for the experiment only
if (void *h = dlopen("libprobe.so", RTLD_NOW)) {
    LOGI("MYGOPROBE dlopen ok");
    dlclose(h);
} else {
    const char *e = dlerror();
    LOGI("MYGOPROBE dlopen failed: %{public}s", e == nullptr ? "(no dlerror)" : e);
}
```

`%{public}s` matters: hilog prints `%s` as `<private>`.
