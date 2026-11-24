#!/bin/sh
# Make a HAP project for any MyGo app: the native shell (NAPI, XComponents,
# IME overlay, host calls) that loads the app's Go code.
#
#   scripts/ohos-init.sh <target-dir> <bundle-name> [app-label]
#
# It copies the shell of mygo-ohos, which is the same for every app: the Go
# code is the app's own, packaged into entry/src/main/cpp/libapp.a by
# scripts/ohos-app.sh.
set -eu

DEST=${1:?usage: ohos-init.sh <target-dir> <bundle-name> [app-label]}
BUNDLE=${2:?usage: ohos-init.sh <target-dir> <bundle-name> [app-label]}
LABEL=${3:-MyGo}

TEMPLATE=${OHOS_TEMPLATE:-$(cd "$(dirname "$0")/../../mygo-ohos" && pwd)}

if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  echo "ohos-init: $DEST is not empty" >&2
  exit 1
fi

echo "== copying the native shell from $TEMPLATE"
mkdir -p "$DEST"
(cd "$TEMPLATE" && tar -cf - \
  AppScope entry/src/main/cpp entry/src/main/ets entry/src/main/resources \
  entry/src/main/module.json5 entry/src/ohosTest entry/oh-package.json5 \
  entry/build-profile.json5 entry/hvigorfile.ts oh-package.json5 \
  oh-package-lock.json5 build-profile.json5 hvigorfile.ts code-linter.json5 \
  .gitignore hvigor/hvigor-config.json5 2>/dev/null) | (cd "$DEST" && tar -xf -)

# The Go archive is the app's, not the shell's, and build outputs are not
# source.
rm -f "$DEST/entry/src/main/cpp/libapp.a"
rm -rf "$DEST/entry/build" "$DEST/build" "$DEST/oh_modules" "$DEST/.hvigor" "$DEST/.idea"

echo "== naming the app $BUNDLE ($LABEL)"
for f in "$DEST/AppScope/app.json5" "$DEST/entry/src/main/module.json5"; do
  [ -f "$f" ] && sed -i "s|\"bundleName\": \"[^\"]*\"|\"bundleName\": \"$BUNDLE\"|" "$f"
done
for f in "$DEST/entry/src/main/resources/base/element/string.json" "$DEST/AppScope/resources/base/element/string.json"; do
  [ -f "$f" ] && sed -i "s|\"value\": \"MyGo\"|\"value\": \"$LABEL\"|; s|\"value\": \"mygo\"|\"value\": \"$LABEL\"|" "$f"
done
sed -i "s|'MyGo'|'$LABEL'|g" "$DEST/entry/src/main/ets/pages/Index.ets" 2>/dev/null || true

# The signing material is the old bundle's: the new one signs with its own
# (devecocli signature generate).
python3 - "$DEST/build-profile.json5" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path).read()
out, i = [], 0
while i < len(src):
    m = re.match(r'\s*"signingConfigs"\s*:\s*\[', src[i:])
    if m:
        j = i + m.end()
        depth = 1
        while j < len(src) and depth:
            if src[j] == '[':
                depth += 1
            elif src[j] == ']':
                depth -= 1
            j += 1
        while j < len(src) and src[j] in ', \t':
            j += 1
        i = j
        continue
    out.append(src[i])
    i += 1
open(path, 'w').write(''.join(out))
PY

cat <<TIP

== done: $DEST

Build and run your app on the device with:

  $(dirname "$0")/ohos-app.sh <path-to-your-mygo-app> "$DEST" run

The app needs to be a MyGo program of its own (its own go.mod, depending on
github.com/egoist/mygo with the openharmony backend), with a main() that
calls mygo.App.Run(), as any MyGo app does.

Signing is per bundle: run

  cd "$DEST" && devecocli signature generate

once before the first build (it binds the device's UDID too).
TIP
