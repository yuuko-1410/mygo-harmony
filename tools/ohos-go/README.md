# The Go of this port

`go1.27.4-ohos` is the `github.com/sysit/ohos-go` fork of the Go tree, at the
commit merging `go1.27.4`, built once on the development machine and left at
`$OHOS_GO` (default `~/Documents/MyProjects/ohos-go/bin/go`). Nothing in
`mygo` depends on where it is: `mygo ohos` finds it through `-go`, `$OHOS_GO`,
or that default, and `mygo ohos doctor` says which one it found.

## The two deltas

`ohos-go.patch` holds them, 9 lines in 5 files:

```
src/runtime/rt0_openharmony_arm64.s     +2  //go:build openharmony
src/runtime/rt0_openharmony_amd64.s     +2  //go:build openharmony
src/mime/type_openharmony.go            +2  //go:build openharmony
src/time/zoneinfo_openharmony.go        +2  //go:build openharmony
src/cmd/link/internal/ld/outbuf_mmap.go ±1  tolerate EACCES from fallocate
```

**The tags**: those four files are known to the Go tool only by their
`_openharmony` filename suffix, which a stock Go does not treat as an OS. A
bootstrap driven by a stock Go therefore compiles them for the host, where
`time/zoneinfo_openharmony.go` and `time/zoneinfo_unix.go` both declare
`platformZoneSources` (`redeclared in this block`). `make.bash` itself does
not need them — its last stage builds with the tree's own `cmd/go`, which
knows the GOOS — but a hand-driven bootstrap does, and so does any stock tool
that reads the tree (`gopls`, `go vet`).

**The EACCES**: a build tree on hmfs, as `/storage` is, fails `fallocate`
with `EACCES`; the linker tolerates `EPERM`/`ENOTSUP` only and dies at
`mapping output file failed: permission denied`, before any Go code is built.
On ext4 or xfs the patch changes nothing.

## Applying

```sh
git clone https://github.com/sysit/ohos-go && cd ohos-go
git checkout 6f933b9d                       # Merge tag 'go1.27.4'
git apply /path/to/mygo/tools/ohos-go/ohos-go.patch
cd src && GOROOT_BOOTSTRAP=$(go env GOROOT) ./make.bash
```

## What we would rather use

`ZxillyFork/go-hmos` is a deeper port of the same idea (a dedicated
OpenHarmony signal table, cgo callbacks, DNS configuration, CPU features,
platform tests). It is a drop-in replacement — same `GOOS=openharmony`, same
`-buildmode=c-archive` — and only needs a source bootstrap on arm64 hosts.
See "The toolchain" in `docs/ohos-port.md`.

## A patch instead of a fork? (untested)

`tls-gd.patch` turns a stock Go 1.27.4 into one whose arm64 c-archives can be
`dlopen`ed: it adds `-tls=LE|IE|GD` to `cmd/asm`, carries the model through
`cmd/internal/obj`, emits `DTPREL` for `GD` in the arm64 backend, and has
`cmd/go` ask for `GD` when it builds an arm64 c-archive. 134 lines of diff,
about 63 added.

It applies to the source tree of a Go 1.27.4 installation (`patch -p1 -d
$(go env GOROOT)`), but it has not been built here: this machine cannot run
`make.bash` (its freshly linked `go_bootstrap` is refused by `execve`). What
is measured is the failure it addresses — see `toolchain-finding.md` — and
that the patch applies cleanly to 1.27.4.

With it, the port builds on a stock Go:

```sh
# in the Go tree: apply the patch, then src/make.bash on a normal machine
export GOOS=linux GOARCH=arm64 CGO_ENABLED=1
export CC="$SDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$SDK/sysroot -D__MUSL__"
go build -tags ohos -buildmode=c-archive -o libapp.a .
```

What that costs, beyond the patch: `runtime.GOOS` is then `linux`, so `time`
reads `/usr/share/zoneinfo` (absent on OpenHarmony: `time.Local` is UTC) and
`mime` reads `/usr/share/mime`. The fork's `time/zoneinfo_openharmony.go` and
`mime/type_openharmony.go` are what those two lines buy.
