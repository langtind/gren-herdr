#!/usr/bin/env bash
# Picker for the gren herdr plugin. fzf over existing gren worktrees; press Enter
# on a match to open it, or type a new name (or pr:<n>/mr:<n>) and press Enter to
# create it with gren — so gren's post-create setup (env, deps, hooks) runs — then
# register the resulting checkout as a native herdr worktree workspace.
set -uo pipefail

herdr=${HERDR_BIN_PATH:-herdr}
plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

for bin in gren jq; do
  command -v "$bin" >/dev/null || { printf '\033[31m%s\033[0m\n' "$bin not found on PATH"; sleep 2; exit 1; }
done

wtjson=$(gren list --format=json 2>/dev/null)

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it. Falls back to a plain read if fzf isn't on PATH.
if command -v fzf >/dev/null; then
  choice=$(
    printf '%s\n' "$wtjson" \
      | jq -r '.[] | select(.branch != null) | .branch' \
      | fzf --print-query --reverse --info=inline --border=rounded --margin=20%,30% \
            --prompt='gren worktree ❯ ' \
            --header='↵ match → open · type new name + ↵ → create · pr:N/mr:N → PR · esc → cancel'
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

if [[ -z $wtpath ]]; then
  # No worktree yet → create with gren. Flags MUST precede any positional ref:
  # Go's flag parser stops at the first non-flag argument.
  if gren_is_prref "$name"; then
    createargs=(create --format=json -y "$name")
  elif git show-ref --quiet --verify "refs/heads/$name"; then
    createargs=(create --format=json -y -n "$name" --existing --branch "$name")
  else
    createargs=(create --format=json -y -n "$name")
  fi

  if ! result=$(gren "${createargs[@]}"); then
    printf '\n\033[31m%s\033[0m press any key to close' "gren create failed (see above)."
    read -rn1
    exit 1
  fi
  wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty')
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
  exec "$herdr" worktree open --workspace "$root_ws" --path "$wtpath" --label "$name" --focus --json
fi
exec "$herdr" worktree open --path "$wtpath" --label "$name" --focus --json
