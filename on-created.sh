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
# The new worktree's root pane (the event's workspace focused pane) — we split it
# so setup shows right below the worktree's own shell.
target=$(jq -r '.focused_pane_id // empty' <<<"$ctx")
hook="$repo_root/.gren/post-create.sh"

# Preferred: run the hook AS a dedicated pane process split below the new
# worktree's shell. A pane's command runs with a real, user-visible TTY (like the
# picker's fzf), so 1Password `op` / `make seed` work and output is live and
# uncapped — and because it's a spawned process (not text typed into a shell)
# there's no shell-startup race. See bootstrap.sh.
if [[ -n $repo_root && -x $hook && -n $target ]]; then
	if "$herdr" plugin pane open \
		--plugin "${HERDR_PLUGIN_ID:-gren}" --entrypoint bootstrap \
		--target-pane "$target" --placement split --direction down --cwd "$path" --no-focus \
		--env "GREN_HERDR_WORKTREE=$path" \
		--env "GREN_HERDR_BRANCH=$branch" \
		--env "GREN_HERDR_REPO_ROOT=$repo_root" >/dev/null 2>&1; then
		echo "opened gren setup pane below $target (branch=${branch:-?})"
		exit 0
	fi
	echo "plugin pane open failed; falling back to inline"
fi

# Fallback: run gren's configured post-create hooks inline (captured output, no
# TTY). Covers custom hook commands, the no-workspace case, and pane-open errors;
# no-ops on non-gren repos.
cd "$path" || { echo "worktree path unavailable: $path"; exit 0; }
echo "gren post-create setup (inline): branch=${branch:-?} path=$path"
exec gren hook-run --type post-create --path "$path" --branch "$branch"
