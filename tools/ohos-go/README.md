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
