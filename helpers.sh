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

# Classify a name typed in the picker into how gren should create it:
#   pr        → a pr:/mr: reference (gren resolves it)
#   existing  → an existing local branch (check it out with --existing)
#   new       → a new branch (create from a chosen base)
# Runs against the git repo in the current directory for the branch check.
gren_herdr_name_kind() {
  local name=$1
  if gren_is_prref "$name"; then
    printf 'pr\n'
  elif git show-ref --quiet --verify "refs/heads/$name"; then
    printf 'existing\n'
  else
    printf 'new\n'
  fi
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

# Open the "bootstrap" plugin pane, which runs gren's configured post-create
# hooks via `gren hook-run --interactive` with a real, user-visible TTY
# (1Password op, make seed) split below the new worktree's shell. Both the
# worktree.created event and the picker use this so setup always runs the same
# way. Gated on the repo being gren-configured (a .gren dir) rather than a
# specific script file, so inline/named hooks reach the TTY too; `hook-run`
# no-ops cleanly on repos with no post-create hooks. Returns non-zero if it
# can't be opened (not a gren repo, or no target pane) so the caller can fall
# back to inline.
#   $1 herdr bin · $2 plugin id · $3 target pane · $4 worktree · $5 branch · $6 repo root
gren_herdr_open_setup_pane() {
  local herdr=$1 plugin_id=$2 target=$3 wt=$4 branch=$5 repo_root=$6
  [[ -n $repo_root && -d "$repo_root/.gren" && -n $target ]] || return 1
  # Focus the setup pane: it runs `gren hook-run --interactive`, which prompts
  # for approval and may run hooks that need input (a TTY). An unfocused split
  # pane isn't painted or given keystrokes until focused, so opening it
  # --no-focus left the approval prompt invisible until the user clicked in.
  "$herdr" plugin pane open \
    --plugin "$plugin_id" --entrypoint bootstrap \
    --target-pane "$target" --placement split --direction down --cwd "$wt" --focus \
    --env "GREN_HERDR_WORKTREE=$wt" \
    --env "GREN_HERDR_BRANCH=$branch" \
    --env "GREN_HERDR_REPO_ROOT=$repo_root" \
    --env "GREN_HERDR_TARGET_PANE=$target" >/dev/null 2>&1
}
