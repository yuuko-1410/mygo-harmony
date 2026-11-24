#!/bin/sh
# Build a MyGo app for OpenHarmony (HarmonyOS) and install it on the
# connected device.
#
#   scripts/ohos-app.sh <app-dir> <hap-project> [run|build]
#
# Needs: the ohos-go toolchain (built once from sysit/ohos-go with the
# machine's own Go), DevEco's native SDK, and devecocli for the HAP.
set -eu

APP=${1:?usage: ohos-app.sh <app-dir> <hap-project> [run|build]}
HAP=${2:?usage: ohos-app.sh <app-dir> <hap-project> [run|build]}
DO=${3:-run}

: "${OHOS_GO:=$HOME/Documents/MyProjects/ohos-go/bin/go}"
: "${OHOS_SDK:=$HOME/.harmonybrew/Cellar/ohos-sdk-native/26.0.0.38}"

CC_TARGET="$OHOS_SDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$OHOS_SDK/sysroot -D__MUSL__"

cd "$APP"
echo "== Go: c-archive for openharmony/arm64"
GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local GOFLAGS=-mod=mod \
  CC="$CC_TARGET" AR="$OHOS_SDK/llvm/bin/llvm-ar" \
  "$OHOS_GO" build -buildmode=c-archive -o libapp.a .
cp libapp.a "$HAP/entry/src/main/cpp/libapp.a"

cd "$HAP"
echo "== HAP: build, sign, install"
if [ "$DO" = run ]; then
  devecocli run
else
  devecocli build
fi
