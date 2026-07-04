#!/usr/bin/env bash
# Picker for the gren herdr plugin. fzf over existing gren worktrees; press Enter
# on a match to switch to it, or type a new name (or pr:<n>/mr:<n>) and press
# Enter to create it with gren (at gren's configured worktree_dir). New worktrees
# are created with --no-hooks and then set up in a dedicated pane with a real TTY
# (so 1Password op / make seed work) — see gren_herdr_open_setup_pane.
set -uo pipefail

herdr=${HERDR_BIN_PATH:-herdr}
plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

for bin in gren jq; do
  command -v "$bin" >/dev/null || { printf '\033[31m%s\033[0m\n' "$bin not found on PATH"; sleep 2; exit 1; }
done

if ! wtjson=$(gren list --format=json 2>/dev/null); then
  printf '\033[31m%s\033[0m\n' "gren list failed — is this a gren-managed git repo?"
  sleep 2
  exit 1
fi

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it. Falls back to a plain read if fzf isn't on PATH.
# Skip detached-HEAD worktrees (empty branch) so they don't show a blank line.
if command -v fzf >/dev/null; then
  choice=$(
    printf '%s\n' "$wtjson" \
      | jq -r '.[] | select(.branch != null and .branch != "") | .branch' 2>/dev/null \
      | fzf --print-query --reverse --info=inline --border=rounded --margin=1,2 --padding=0,1 \
            --prompt='switch / create ❯ ' \
            --header='TYPE A NEW NAME → create it   ·   ↵ on a match → switch to it   ·   pr:N/mr:N → check out PR   ·   esc → cancel'
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0      # 130 = esc/abort → cancel (0 = picked, 1 = typed-new)
  name=${choice##*$'\n'}          # last line: the selection if any, else the typed query
else
  printf 'Branch (existing → open · new → create): '
  read -r name
fi
[[ -z $name ]] && exit 0

# If the name already has a worktree, just open it — its setup already ran.
wtpath=$(printf '%s\n' "$wtjson" \
  | jq -r --arg b "$name" '.[] | select(.branch == $b) | .path' | head -n1)

created=""
if [[ -z $wtpath ]]; then
  # No worktree yet → create with gren, but --no-hooks: we run post-create
  # ourselves afterwards in a pane with a real TTY. Flags MUST precede any
  # positional ref — Go's flag parser stops at the first non-flag argument.
  case $(gren_herdr_name_kind "$name") in
    pr)
      createargs=(create --no-hooks --format=json -y "$name") ;;
    existing)
      createargs=(create --no-hooks --format=json -y -n "$name" --existing --branch "$name") ;;
    *)
      # New branch → let the user pick the base (like gren's TUI). esc cancels.
      base=$(gren_herdr_pick_base "$name")
      [[ -z $base ]] && exit 0
      createargs=(create --no-hooks --format=json -y -n "$name" -b "$base") ;;
  esac

  if ! result=$(gren "${createargs[@]}"); then
    printf '\n\033[31m%s\033[0m press any key to close' "gren create failed (see above)."
    read -rn1
    exit 1
  fi
  wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty')
  created=1
fi

if [[ -z $wtpath ]]; then
  printf '\033[31m%s\033[0m\n' "gren returned no worktree path for: $name"
  sleep 2
  exit 1
fi

# Register under the repo's ROOT workspace, not the picker pane's current
# workspace. Run from inside an existing worktree workspace and `worktree open`
# rejects it with `linked_worktree_source`; herdr resolves the repo root from any
# checkout cwd via .result.source.source_workspace_id, so prefer that.
root_ws=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null \
  | jq -r '.result.source.source_workspace_id // empty')
[[ -z $root_ws ]] && root_ws=${HERDR_WORKSPACE_ID:-}

if [[ -n $root_ws ]]; then
  open=$("$herdr" worktree open --workspace "$root_ws" --path "$wtpath" --label "$name" --focus --json 2>/dev/null)
else
  open=$("$herdr" worktree open --path "$wtpath" --label "$name" --focus --json 2>/dev/null)
fi

# Surface a failed registration instead of silently continuing to setup.
if [[ -z $(printf '%s\n' "$open" | jq -r '.result // empty' 2>/dev/null) ]]; then
  msg=$(printf '%s\n' "$open" | jq -r '.error.message // empty' 2>/dev/null)
  printf '\n\033[31m%s\033[0m press any key to close' "herdr worktree open failed: ${msg:-unknown error}"
  read -rn1
  exit 1
fi

# For a freshly created worktree, run gren's post-create setup in a pane with a
# real TTY (we created with --no-hooks). Switching to an existing worktree needs
# no setup — it already ran when that worktree was created.
if [[ -n $created ]]; then
  root_pane=$(printf '%s\n' "$open" | jq -r '.result.root_pane.pane_id // empty')
  branch=$(git -C "$wtpath" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "$name")
  repo_root=$(git -C "$wtpath" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [[ -n $repo_root ]] && repo_root=$(cd "$repo_root/.." 2>/dev/null && pwd)
  gren_herdr_open_setup_pane "$herdr" "${HERDR_PLUGIN_ID:-gren}" "$root_pane" "$wtpath" "$branch" "$repo_root" \
    || { cd "$wtpath" 2>/dev/null && exec gren hook-run --type post-create --path "$wtpath" --branch "$branch"; }
fi
