#!/usr/bin/env bash
# Runs as a herdr plugin PANE process (opened by on-created.sh into the new
# worktree's workspace), so it has a real, user-visible TTY — interactive setup
# like 1Password `op` biometric unlock and `make seed` work, with live uncapped
# output. This avoids the flaky "type into a freshly-spawned shell" approach.
#
# Inputs come from the env the event passes via `plugin pane open --env`:
#   GREN_HERDR_WORKTREE, GREN_HERDR_BRANCH, GREN_HERDR_REPO_ROOT
# with the pane cwd as a fallback for the worktree path.
set -uo pipefail

wt=${GREN_HERDR_WORKTREE:-$PWD}
branch=${GREN_HERDR_BRANCH:-}
repo_root=${GREN_HERDR_REPO_ROOT:-}

if [[ -z $repo_root ]]; then
	common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	[[ -n $common ]] && repo_root=$(cd "$common/.." 2>/dev/null && pwd)
fi

hook="$repo_root/.gren/post-create.sh"
if [[ -z $repo_root || ! -x $hook ]]; then
	echo "no gren post-create hook at ${hook:-<unknown>}; nothing to do"
	exit 0
fi

# Branch is what gren's hook expects as $2 and what `gren delete` matches on.
[[ -z $branch ]] && branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

cd "$wt" || { echo "worktree unavailable: $wt"; exit 0; }

# gren post-create args: WORKTREE_PATH BRANCH_NAME BASE_BRANCH REPO_ROOT.
# The event carries no base ref; post-create only uses it for failure hints.
echo "🌳 gren post-create setup for ${branch:-?} …"
echo
if "$hook" "$wt" "$branch" "" "$repo_root"; then
	exit 0
fi
rc=$?
# Keep the pane open on failure so the error stays visible for debugging.
printf '\n\033[31mgren post-create hook failed (exit %s).\033[0m press any key to close\n' "$rc"
read -rn1 || true
exit "$rc"
