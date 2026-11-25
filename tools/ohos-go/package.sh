#!/bin/sh
# Packages a built OpenHarmony Go tree as the tarball a machine installs
# instead of bootstrapping it: a HarmonyOS PC has no terminal to run
# make.bash in, and building a Go tree needs one.
#
#   tools/ohos-go/package.sh [tree] [out]
#
# tree is the checkout whose src/make.bash ran ($OHOS_GO's GOROOT, by
# default), out the tarball (go1.27.4-ohos-<host>.tar.gz, by default, the way
# sysit/ohos-go names its releases). The tarball unpacks as "go/", the layout
# GOROOT wants, with a .sha256 beside it.
set -eu

TREE=${1:-}
if [ -z "$TREE" ]; then
  go=${OHOS_GO:-$HOME/Documents/MyProjects/ohos-go/bin/go}
  TREE=$("$go" env GOROOT)
fi
if [ ! -x "$TREE/bin/go" ] || [ ! -d "$TREE/src/cmd/go" ]; then
  echo "package.sh: $TREE is not a built Go tree (bin/go, src/)" >&2
  exit 1
fi

version=$(cat "$TREE/VERSION")
host=$("$TREE/bin/go" env GOHOSTOS)-$("$TREE/bin/go" env GOHOSTARCH)
out=${2:-go${version}-${host}.tar.gz}

# src/ travels: a cross-build compiles the standard library on demand, and
# lib/ holds the time zone database a hermetic build reads.
cd "$TREE"
tar -czf "$out" \
  --transform 's,^,go/,' \
  VERSION go.env LICENSE PATENTS \
  bin pkg src lib api

sha256sum "$out" > "$out.sha256"
echo "$out: $(du -h "$out" | cut -f1)"
echo
echo "Attach it to a release of your fork of the Go tree. A machine installs it with:"
echo "  tar -xzf $out -C \$HOME/sdk   # gives \$HOME/sdk/go/bin/go"
echo "  OHOS_GO=\$HOME/sdk/go/bin/go mygo ohos doctor"
