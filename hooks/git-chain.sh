#!/bin/sh
# Copied to <worktree git dir>/shepherd/_githooks/chain by `shepherd init`.
# That dir is this worktree's core.hooksPath, which replaces the repo's own
# hooks dir, so each hook stub there calls this to run the repo's hook of the
# same name: core.hooksPath from the local, global, or system config (relative
# to the worktree root), else <common git dir>/hooks. stdin passes through.
# usage: chain HOOK_NAME [ARGS...]

name=$1
shift
self=$(cd "$(dirname "$0")" && pwd -P)
dir=
for scope in local global system; do
  dir=$(git config "--$scope" --includes --path core.hooksPath 2>/dev/null) && [ -n "$dir" ] && break
  dir=
done
case $dir in
  "") dir=$(git rev-parse --path-format=absolute --git-common-dir)/hooks ;;
  /*) ;;
  *) dir=$(git rev-parse --show-toplevel)/$dir ;;
esac
[ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$self" ] && exit 0
[ -x "$dir/$name" ] || exit 0
exec "$dir/$name" "$@"
