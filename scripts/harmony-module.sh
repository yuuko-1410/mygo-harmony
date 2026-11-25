#!/bin/sh
# Rewrites the module path to the fork's, on the tip commit of `ohos-port`.
#
# The rename is one commit, always the tip: the port's own commits keep
# `github.com/egoist/mygo`, so they replay onto upstream without dragging a
# thousand rewritten import lines through every rebase. After syncing:
#
#   git commit --allow-empty -m "harmony: rename the module"   # once
#   sh scripts/harmony-module.sh                              # after each rebase
#
# Only the module path changes; the npm names (mygo-cli, mygo-runtime,
# @mygo-plugins/*) stay as upstream has them.
set -eu
cd "$(git rev-parse --show-toplevel)"

subject="harmony: rename the module"
from=github.com/egoist/mygo
to=github.com/yuuko-1410/mygo-harmony
self=scripts/harmony-module.sh
backup=.renaming.bak

if [ "$(git log -1 --pretty=%s)" != "$subject" ]; then
	echo "the tip is not '$subject': rebase, commit that subject, then run this" >&2
	exit 1
fi

# git grep lists tracked files only, so node_modules/, .mygo/ and dist/ are out.
# One sed for the lot: a hundred milliseconds a file adds up over the ~1500
# files that spell the module path, and the backup suffix is the one form of
# -i that BSD, GNU and toybox sed all agree on.
files=$(mktemp)
trap 'rm -f "$files"' EXIT
git grep -lzF "$from" -- . ":(exclude)$self" > "$files" || true
if [ ! -s "$files" ]; then
	echo "nothing to rename"
	exit 0
fi

xargs -0 sed -i"$backup" "s|$from|$to|g" < "$files"

n=$(find . -name "*$backup" -not -path './.git/*' -print | wc -l | tr -d ' ')
find . -name "*$backup" -not -path './.git/*' -delete

git add -u
git commit --amend --no-edit
echo "renamed $n files into $(git log -1 --pretty=%h)"
