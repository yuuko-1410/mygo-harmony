#!/bin/sh
# Keeps mygo-harmony in step with egoist/mygo: `main` mirrors upstream and
# carries no commit of ours, `ohos-port` carries the port and rides on main.
#
#   sh scripts/sync-upstream.sh
#
# It never checks `main` out, so this file, which only exists on `ohos-port`,
# survives its own run. Needs two remotes: `origin` is the fork
# (yuuko-1410/mygo-harmony), `upstream` is egoist/mygo.
set -eu
cd "$(git rev-parse --show-toplevel)"

port=ohos-port

git fetch upstream --prune --tags
git fetch origin --prune

# main is a mirror: fast-forward it to upstream, here and on the fork. The
# push has no `+`, so if a commit ever landed on main this fails loudly
# instead of throwing it away.
git branch -f main upstream/main
git push origin upstream/main:refs/heads/main

# The port's own commits keep upstream's module path, so replaying them only
# conflicts where we edit a file upstream edited too. `rerere` remembers each
# of those resolutions: git config --global rerere.enabled true
git switch "$port"
git rebase upstream/main
git push --force-with-lease origin "$port"

# If the tip is the module rename, refresh it for the new upstream: `sh
# scripts/harmony-module.sh`.
echo "done: $port is on $(git log -1 --pretty=%h) over $(git rev-parse --short upstream/main)"
