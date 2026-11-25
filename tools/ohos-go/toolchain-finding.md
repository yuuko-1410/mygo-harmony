# What a stock Go cannot do, measured

Question: can the OpenHarmony port build on upstream Go, as the review asked,
with `GOOS=linux GOARCH=arm64 -buildmode=c-archive` and the NDK's clang?

Measured on a HarmonyOS 2-in-1 with Go 1.27.4 (stock) and the same tree built
by `sysit/ohos-go`.

## Building: yes

With the port's files tagged `//go:build openharmony || (linux && ohos)`, the
seven linux backends excluded by `&& !ohos`, and the six `*_other.go` link
stubs widened with `|| ohos`:

- stock Go compiles the whole port to a c-archive (32.27 MB; the fork's is
  32.26 MB), and hvigor links `libentry.so` from it with no undefined symbol;
- `DT_NEEDED` of the result lists only OHOS libraries (no `libpthread`,
  `libdl` or `libresolv`, which musl does not ship separately).

So the `-D__MUSL__` hypothesis in the review holds: the cgo half is fine.

## Loading: no

At run time the module does not load. ArkTS's `import native from
'libentry.so'` is `undefined`, the page throws at its first `native.…` call,
and the process is killed ("Kill Reason: Js Error").

The same happens with an eighteen-function stub (`napi-stub/`), so nothing of
the port's backend is involved.

## The difference: one TLS relocation

| archive | in `libentry.so` |
|---|---|
| stock Go | `.tbss` 16 bytes; `runtime.tls_g`, `runtime.tlsg`; **1 × `R_AARCH64_TLS_TPREL64`** |
| the fork | `.tbss` 16 bytes; `runtime.tls_g`, `runtime.tlsg`; **no TLS relocation** |

ArkTS loads a NAPI module with `dlopen`, where initial-exec TLS is not
permitted; general-dynamic is. The stock build's `runtime.tlsg` is assembled
initial-exec, and nothing on the command line changes that:
`-gcflags=all=-shared` and `-ldflags=-linkmode=external` were both tried and
leave the relocation in place.

Upstream Go has no TLS-model switch at all. The fork's is:

```
cmd/asm/internal/flags/flags.go   +1   -tls=LE|IE|GD
cmd/asm/main.go                  +13   pass it to the assembler
cmd/internal/obj/link.go          +1   carry it in the Prog
cmd/internal/obj/arm64/a.out.go   +4   the models
cmd/internal/obj/arm64/asm7.go   +33   emit TLS_GD/DTPREL instead of TPREL
cmd/go/internal/work/init.go     +34   ask for GD for c-archive/c-shared on
                                       arm64, and pass -D=TLS_GD
```

About 85 lines in six files, on arm64 (`cmd/internal/obj/x86/asm6.go` adds 43
more for amd64). That is the part of the fork a port cannot do without, and it
is the size of the patch the review would have to weigh against a third-party
toolchain: not a fork to pin, but a change to carry.

## What this means for the review's question

- stock Go builds the port and its `libentry.so`; it cannot produce a module
  that `dlopen` accepts, and no build flag changes that;
- the fix is a TLS-model switch in the assembler and the go command, ~85 lines;
- everything else the fork carries (`zgoos_openharmony.go`, `rt0`, the
  `linux` filename alias, `time`/`mime`/`net` tables, `dist`'s OS list) is
  either unnecessary for a c-archive or small enough to keep as a patch;
- if the project would rather not carry a toolchain patch at all, the port
  stays on the fork, as it is today.
