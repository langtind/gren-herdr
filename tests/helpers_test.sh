#!/usr/bin/env bash
# Unit tests for helpers.sh. Run: bash tests/helpers_test.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../helpers.sh
source "$here/../helpers.sh"

fail=0
check() { # description  expected_rc  actual_rc
  if [[ $2 -ne $3 ]]; then
    printf 'FAIL: %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
    fail=1
  else
    printf 'ok: %s\n' "$1"
  fi
}

gren_is_prref "pr:42";      check "pr:42 is a PR ref"        0 $?
gren_is_prref "mr:7";       check "mr:7 is an MR ref"        0 $?
gren_is_prref "feature/x";  check "feature/x is not a ref"   1 $?
gren_is_prref "main";       check "main is not a ref"        1 $?
gren_is_prref "fix-pr:bug"; check "fix-pr:bug is not a ref"  1 $?
gren_is_prref "";           check "empty is not a ref"       1 $?

check_eq() { # description  expected  actual
  if [[ "$2" != "$3" ]]; then
    printf 'FAIL: %s (expected %q, got %q)\n' "$1" "$2" "$3"
    fail=1
  else
    printf 'ok: %s\n' "$1"
  fi
}

# gren_herdr_name_kind + gren_herdr_pick_base need a git repo with branches.
_orig=$(pwd)
_repo=$(mktemp -d)
git -C "$_repo" init -q -b main
git -C "$_repo" config user.email t@e.com
git -C "$_repo" config user.name T
printf 'x\n' >"$_repo/f"
git -C "$_repo" add -A
git -C "$_repo" commit -qm init
git -C "$_repo" branch feat/a
cd "$_repo" || exit 1

check_eq "name_kind pr:42 → pr"        "pr"       "$(gren_herdr_name_kind 'pr:42')"
check_eq "name_kind existing branch"   "existing" "$(gren_herdr_name_kind 'feat/a')"
check_eq "name_kind main → existing"   "existing" "$(gren_herdr_name_kind 'main')"
check_eq "name_kind new branch → new"  "new"      "$(gren_herdr_name_kind 'brand-new')"

# pick_base lists the default (main) first; a stub fzf that echoes line 1 returns it.
_stub=$(mktemp -d)
printf '#!/usr/bin/env bash\nhead -1\n' >"$_stub/fzf"
chmod +x "$_stub/fzf"
check_eq "pick_base default = main" "main" "$(PATH="$_stub:$PATH" gren_herdr_pick_base 'x')"

# gren_herdr_open_setup_pane gates on the repo being gren-configured (a .gren dir)
# and a target pane, before invoking herdr. Guard cases need no herdr at all.
gren_herdr_open_setup_pane "true" "gren" "pane1" "$_repo" "main" "$_repo"
check "open_setup_pane: no .gren dir → skip" 1 $?

mkdir -p "$_repo/.gren"
gren_herdr_open_setup_pane "true" "gren" "" "$_repo" "main" "$_repo"
check "open_setup_pane: no target pane → skip" 1 $?

# Success path: stub herdr records its args so we can assert the target-pane env
# (used for the port badge) is plumbed through.
cat >"$_stub/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HSTUB_OUT"
exit 0
STUB
chmod +x "$_stub/herdr"
export HSTUB_OUT="$_stub/args"
gren_herdr_open_setup_pane "$_stub/herdr" "gren" "pane1" "$_repo" "main" "$_repo"
check "open_setup_pane: gren repo + target → open" 0 $?
grep -q -- "GREN_HERDR_TARGET_PANE=pane1" "$_stub/args"
check "open_setup_pane: plumbs target-pane env" 0 $?

# gren_herdr_worktree_path_for_branch resolves a branch's worktree path via
# `gren list --format=json` (stubbed here) — the picker's recovery when create
# succeeded but its stdout wasn't parseable JSON.
cat >"$_stub/gren" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "list" ]] || exit 1
printf '[{"branch":"feat/a","path":"/tmp/wt-a"},{"branch":"main","path":"/tmp/main-wt"}]\n'
STUB
chmod +x "$_stub/gren"
check_eq "path_for_branch: match → path"     "/tmp/wt-a" "$(PATH="$_stub:$PATH" gren_herdr_worktree_path_for_branch 'feat/a')"
check_eq "path_for_branch: unknown → empty"  ""          "$(PATH="$_stub:$PATH" gren_herdr_worktree_path_for_branch 'nope')"

printf '#!/usr/bin/env bash\nexit 1\n' >"$_stub/gren"
check_eq "path_for_branch: gren failure → empty" "" "$(PATH="$_stub:$PATH" gren_herdr_worktree_path_for_branch 'feat/a')"

cd "$_orig" || exit 1
rm -rf "$_repo" "$_stub"

if [[ $fail -eq 0 ]]; then
  printf '\nall helper tests passed\n'
else
  printf '\nsome helper tests FAILED\n'
fi
exit $fail
