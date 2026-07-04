#!/usr/bin/env bash
# Remover for the gren herdr plugin — fzf over removable worktrees, then
# `gren delete`. gren prompts for confirmation and runs its pre-remove hooks, so
# run it interactively in the pane and let gren gate the destructive part.
set -uo pipefail

herdr=${HERDR_BIN_PATH:-herdr}

for bin in gren jq fzf; do
  command -v "$bin" >/dev/null || { printf '\033[31m%s\033[0m\n' "$bin not found on PATH"; sleep 2; exit 1; }
done

wtjson=$(gren list --format=json 2>/dev/null)

# Removable = any worktree except the main checkout (which can't be removed).
cands=$(printf '%s\n' "$wtjson" \
  | jq -r '.[] | select(.branch != null and .is_main != true) | .branch')
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."
  sleep 2
  exit 0
fi

name=$(printf '%s\n' "$cands" \
  | fzf --reverse --info=inline --border=rounded --margin=1,2 --padding=0,1 \
        --prompt='remove worktree ❯ ' \
        --header='↵ to remove (gren will ask to confirm) · esc to cancel')
[[ -z $name ]] && exit 0      # esc / no selection → cancel

# Capture path + native herdr workspace BEFORE deletion — the path is gone after.
wtpath=$(printf '%s\n' "$wtjson" | jq -r --arg b "$name" '.[] | select(.branch==$b) | .path' | head -n1)
wsid=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null \
  | jq -r --arg p "$wtpath" \
      '.result.worktrees[] | select(.path == $p) | .open_workspace_id // empty' \
  | head -n1)

# gren delete prompts (y/N), refuses without confirmation, and runs pre-remove hooks.
if ! gren delete "$name"; then
  printf '\n\033[31m%s\033[0m press any key to close' "gren delete failed or was cancelled (see above)."
  read -rn1
  exit 0
fi

# Close the native worktree workspace as a unit. Fall back to closing panes whose
# cwd is inside the removed checkout (for tab-based or externally-opened worktrees).
if [[ -n $wsid ]]; then
  "$herdr" workspace close "$wsid"
elif [[ -n $wtpath && $wtpath != "/" ]]; then
  "$herdr" pane list 2>/dev/null \
    | jq -r --arg p "$wtpath" --arg self "${HERDR_PANE_ID:-}" \
        '.result.panes[] | select(.pane_id != $self)
         | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .pane_id' \
    | while read -r pid; do "$herdr" pane close "$pid"; done
fi
