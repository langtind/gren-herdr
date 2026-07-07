#!/usr/bin/env bash
# Runs as a herdr plugin PANE process (opened by on-created.sh / the picker into
# the new worktree's workspace), so it has a real, user-visible TTY — interactive
# setup like 1Password `op` biometric unlock and `make seed` work, with live
# uncapped output. This avoids the flaky "type into a freshly-spawned shell".
#
# It routes through gren's own hook engine via `gren hook-run --interactive`, so
# the FULL hook config runs — inline commands, script hooks, named hooks with
# branch filters, and user-level hooks — with approval (prompted once per
# project, then remembered) and per-worktree templating ({{ branch | hash_port }}
# et al.). This is a superset of running `.gren/post-create.sh` directly.
#
# Inputs come from the env the event passes via `plugin pane open --env`:
#   GREN_HERDR_WORKTREE, GREN_HERDR_BRANCH, GREN_HERDR_REPO_ROOT, GREN_HERDR_TARGET_PANE
# with the pane cwd as a fallback for the worktree path.
set -uo pipefail

wt=${GREN_HERDR_WORKTREE:-$PWD}
branch=${GREN_HERDR_BRANCH:-}
repo_root=${GREN_HERDR_REPO_ROOT:-}
target_pane=${GREN_HERDR_TARGET_PANE:-}
herdr=${HERDR_BIN_PATH:-herdr}

if ! command -v gren >/dev/null; then
	echo "gren not on PATH; nothing to do"
	exit 0
fi

if [[ -z $repo_root ]]; then
	common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	[[ -n $common ]] && repo_root=$(cd "$common/.." 2>/dev/null && pwd)
fi

# Branch is what gren's hook expects as $2 and what `gren delete` matches on.
[[ -z $branch ]] && branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

cd "$wt" || { echo "worktree unavailable: $wt"; exit 0; }

# Best-effort: surface this worktree's deterministic per-branch dev port on its
# own pane, so you can tell at a glance which worktree owns which port. Uses the
# same engine the hooks do, so the number matches. Never fatal.
if [[ -n $target_pane && -n $branch ]]; then
	port=$(gren step eval '{{ branch | hash_port }}' 2>/dev/null || true)
	if [[ -n $port ]]; then
		"$herdr" pane report-metadata "$target_pane" \
			--source "${HERDR_PLUGIN_ID:-gren}" \
			--custom-status "port $port" >/dev/null 2>&1 || true
	fi
fi

echo "🌳 gren post-create setup for ${branch:-?} …"
echo
# Run gren's configured post-create hooks with a real TTY + approval. No-ops
# cleanly on repos with no post-create hooks (stays quiet for non-gren projects).
# The event carries no base ref; post-create only uses it for failure hints.
gren hook-run --type post-create --path "$wt" --branch "$branch" --base "" --interactive
rc=$?
[[ $rc -eq 0 ]] && exit 0
# Keep the pane open on failure so the error stays visible for debugging, and
# point at the on-disk capture so the cause is recoverable after the pane closes.
printf '\n\033[31mgren post-create hook failed (exit %s).\033[0m\n' "$rc"
printf 'Full output saved — run: \033[36mgren logs --last\033[0m\n'
printf 'press any key to close\n'
read -rn1 || true
exit "$rc"
