#!/usr/bin/env bash

# True when NAME is a gren PR/MR reference (pr:<n> / mr:<n>) that gren resolves
# itself via `gren create <ref>`. Git branch names can't contain ':', so these
# must be passed to gren as-is, never with -n/--branch as a plain branch name.
gren_is_prref() {
  case $1 in
    pr:*|mr:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Let the user choose the base branch for a NEW worktree branch, matching gren's
# TUI. Lists local branches with the recommended default first (main/master, else
# the current branch) so Enter accepts it. Prints the chosen base, or nothing if
# cancelled. $1 = the new branch name (for the prompt).
gren_herdr_pick_base() {
  local for_name=$1 default_base b list base
  default_base=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  for b in main master; do
    if git show-ref --quiet --verify "refs/heads/$b"; then default_base=$b; break; fi
  done

  if [[ -n $default_base ]]; then
    list=$(printf '%s\n' "$default_base"; git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -vxF "$default_base")
  else
    list=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
  fi

  if command -v fzf >/dev/null; then
    printf '%s\n' "$list" \
      | fzf --reverse --info=inline --border=rounded --margin=1,2 --padding=0,1 \
            --prompt="base for ${for_name} ❯ " \
            --header="base branch for the new worktree (↵ = ${default_base:-first}) · esc → cancel"
  else
    printf 'Base branch [%s]: ' "$default_base" >&2
    read -r base
    printf '%s\n' "${base:-$default_base}"
  fi
}

# Open the "bootstrap" plugin pane, which runs the repo's .gren/post-create.sh
# with a real, user-visible TTY (1Password op, make seed) split below the new
# worktree's shell. Both the worktree.created event and the picker use this so
# setup always runs the same way. Returns non-zero if it can't be opened (no
# hook script, or no target pane) so the caller can fall back.
#   $1 herdr bin · $2 plugin id · $3 target pane · $4 worktree · $5 branch · $6 repo root
gren_herdr_open_setup_pane() {
  local herdr=$1 plugin_id=$2 target=$3 wt=$4 branch=$5 repo_root=$6
  [[ -n $repo_root && -x "$repo_root/.gren/post-create.sh" && -n $target ]] || return 1
  "$herdr" plugin pane open \
    --plugin "$plugin_id" --entrypoint bootstrap \
    --target-pane "$target" --placement split --direction down --cwd "$wt" --no-focus \
    --env "GREN_HERDR_WORKTREE=$wt" \
    --env "GREN_HERDR_BRANCH=$branch" \
    --env "GREN_HERDR_REPO_ROOT=$repo_root" >/dev/null 2>&1
}
