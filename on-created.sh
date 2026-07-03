#!/usr/bin/env bash
# herdr event hook for `worktree.created`. Runs gren's post-create setup on a
# worktree that herdr just created — via the native "New worktree" dialog, the
# repo right-click menu, or `herdr worktree create`.
#
# Preferred path: run the repo's `.gren/post-create.sh` IN the new worktree's own
# pane (via `herdr pane run`) so setup gets a real TTY (interactive tools like
# 1Password `op` biometric unlock, `make seed`), live uncapped output, and the
# worktree's own direnv-loaded shell env. gren runs *simple* hooks with captured
# stdio (no TTY), so a detached event hook can't provide one — the pane can.
#
# Fallbacks: when no `.gren/post-create.sh` exists (e.g. a custom hook command)
# or no pane is available, run `gren hook-run` inline. That respects the full
# gren hook config and no-ops cleanly on repos with no post-create hooks — so
# this stays quiet for non-gren projects.
set -uo pipefail

command -v gren >/dev/null || { echo "gren not on PATH; skipping post-create setup"; exit 0; }
command -v jq   >/dev/null || { echo "jq not on PATH; skipping post-create setup"; exit 0; }

ctx=${HERDR_PLUGIN_CONTEXT_JSON:-}
[[ -z $ctx ]] && ctx='{}'

# herdr's worktree.created context carries a worktree "membership" record:
# .worktree.checkout_path is the new checkout; there is no branch field.
path=$(jq -r '.worktree.checkout_path // .worktree.path // .workspace_cwd // empty' <<<"$ctx")
if [[ -z $path || ! -d $path ]]; then
	echo "no worktree path in event context; nothing to do"
	exit 0
fi

# Only act on real linked worktrees, never the main checkout.
is_linked=$(jq -r '.worktree.is_linked_worktree // empty' <<<"$ctx")
if [[ -n $is_linked && $is_linked != "true" ]]; then
	echo "not a linked worktree (is_linked=$is_linked); skipping"
	exit 0
fi

# Branch is not in the worktree.created context, so recover it from git (this is
# what gren's hooks expect as $2 and what `gren delete` matches on).
branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# Repo root of the main checkout (where .gren lives) — from context, or resolved
# from the worktree's git common dir.
repo_root=$(jq -r '.worktree.repo_root // empty' <<<"$ctx")
if [[ -z $repo_root ]]; then
	common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	[[ -n $common ]] && repo_root=$(cd "$common/.." 2>/dev/null && pwd)
fi

herdr=${HERDR_BIN_PATH:-herdr}
pane=${HERDR_PANE_ID:-}
[[ -z $pane ]] && pane=$(jq -r '.focused_pane_id // empty' <<<"$ctx")

hook="$repo_root/.gren/post-create.sh"

# Preferred: run the hook script directly in the new worktree's pane for a real TTY.
if [[ -n $repo_root && -x $hook && -n $pane ]]; then
	# gren post-create args: WORKTREE_PATH BRANCH_NAME BASE_BRANCH REPO_ROOT.
	# The event carries no base ref; post-create only uses it for failure hints.
	run_cmd="cd $(printf '%q' "$path") && $(printf '%q' "$hook") $(printf '%q' "$path") $(printf '%q' "$branch") '' $(printf '%q' "$repo_root")"
	# Let the freshly spawned shell finish init (direnv/prompt) so the typed
	# command isn't swallowed by shell startup.
	sleep 2
	"$herdr" pane run "$pane" "$run_cmd"
	echo "dispatched gren post-create to pane $pane (branch=${branch:-?})"
	exit 0
fi

# Fallback: run gren's configured post-create hooks inline (captured output, no
# TTY). Covers custom hook commands and the no-pane case; no-ops on non-gren repos.
cd "$path" || { echo "worktree path unavailable: $path"; exit 0; }
echo "gren post-create setup (inline): branch=${branch:-?} path=$path"
exec gren hook-run --type post-create --path "$path" --branch "$branch"
