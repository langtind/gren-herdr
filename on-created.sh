#!/usr/bin/env bash
# herdr event hook for `worktree.created`. Runs gren's post-create setup
# (env-symlinks, dependency install, project post-create hooks) on a worktree
# that herdr just created — via the native "New worktree" dialog, the repo
# right-click menu, or `herdr worktree create`. Output lands in the plugin log:
#   herdr plugin log list --plugin gren
#
# It is a no-op (exit 0) when gren isn't installed or the repo isn't
# gren-initialized, so it stays quiet for non-gren projects.
set -uo pipefail

command -v gren >/dev/null || { echo "gren not on PATH; skipping post-create setup"; exit 0; }
command -v jq   >/dev/null || { echo "jq not on PATH; skipping post-create setup"; exit 0; }

ctx=${HERDR_PLUGIN_CONTEXT_JSON:-}
[[ -z $ctx ]] && ctx='{}'

# herdr's worktree.created context carries a worktree "membership" record:
# .worktree.checkout_path is the new checkout, and there is no branch field.
# Fall back through the documented WorktreeInfo fields and the workspace cwd.
path=$(jq -r '.worktree.checkout_path // .worktree.path // .workspace_cwd // empty' <<<"$ctx")

if [[ -z $path || ! -d $path ]]; then
  echo "no worktree path in event context; nothing to do"
  exit 0
fi

# Run from inside the new worktree so gren resolves the correct repo and config.
cd "$path" || { echo "worktree path unavailable: $path"; exit 0; }

# Branch is not included in the worktree.created context, so recover it from git.
branch=$(jq -r '.worktree.branch // empty' <<<"$ctx")
[[ -n $branch ]] || branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)

echo "gren post-create setup: branch=${branch:-?} path=$path"
# gren hook-run auto-approves and no-ops when the repo has no post-create hooks.
exec gren hook-run --type post-create --path "$path" --branch "$branch"
