#!/usr/bin/env bash
# End-to-end picker test with stubbed gren/fzf/herdr. Run: bash tests/picker_test.sh
#
# Reproduces the 2026-07-12 incident: `gren create --format=json` exits 0 but
# prints a warning line ahead of the JSON payload (gren < 0.18.1 did this when
# the base branch had unpushed commits), so the picker's `jq -r '.path'` parse
# fails. The picker must recover the path from `gren list` and continue with
# registration + the setup pane — not abort and leave a created-but-never-set-up
# worktree behind.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail=0
check() { # description  expected_rc  actual_rc
  if [[ $2 -ne $3 ]]; then
    printf 'FAIL: %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
    fail=1
  else
    printf 'ok: %s\n' "$1"
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The main checkout the picker runs from — a real git repo, gren-configured
# (.gren dir) so the setup pane isn't skipped.
repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email t@e.com
git -C "$repo" config user.name T
printf 'x\n' >"$repo/f"
git -C "$repo" add -A
git -C "$repo" commit -qm init
mkdir -p "$repo/.gren"

# The worktree the stubbed create "makes" — a real git worktree (as gren would
# make it), so the picker can resolve branch + repo root for the setup pane.
wt="$work/repo-worktrees/brand-new"
git -C "$repo" worktree add -b brand-new "$wt" >/dev/null 2>&1

stubs="$work/stubs"
state="$work/state"
mkdir -p "$stubs" "$state"

# fzf stub: the user types a name that has no worktree yet. The same stub also
# serves the base-branch pick; the gren stub ignores the base, so the value is
# irrelevant there.
cat >"$stubs/fzf" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'brand-new\n'
STUB

# gren stub: list omits brand-new before create (so the picker takes the create
# path) and includes it after — which is what recovery relies on. create exits 0
# but emits the polluted stdout of gren < 0.18.1.
cat >"$stubs/gren" <<STUB
#!/usr/bin/env bash
case "\$1" in
  list)
    if [[ -f "$state/created" ]]; then
      printf '[{"name":"brand-new","branch":"brand-new","path":"%s","is_current":false,"is_main":false,"status":"clean"}]\n' "$wt"
    else
      printf '[]\n'
    fi
    ;;
  create)
    touch "$state/created"
    printf '⚠️ main has 1 unpushed commit(s) - using local version\n'
    printf '{"name":"brand-new","branch":"brand-new","path":"%s"}\n' "$wt"
    ;;
  hook-run)
    printf 'hook-run %s\n' "\$*" >>"$state/gren-calls"
    ;;
esac
exit 0
STUB

# herdr stub: records every call; `worktree open` answers with a success result
# so the picker proceeds to the setup pane.
cat >"$stubs/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$state/herdr-calls"
if [[ "\$1" == "worktree" && "\$2" == "open" ]]; then
  printf '{"result":{"root_pane":{"pane_id":"p9"}}}\n'
fi
exit 0
STUB
chmod +x "$stubs/fzf" "$stubs/gren" "$stubs/herdr"

cd "$repo" || exit 1
PATH="$stubs:$PATH" HERDR_BIN_PATH="$stubs/herdr" HERDR_PLUGIN_ID=gren \
  bash "$here/../picker.sh" </dev/null >"$state/picker-out" 2>&1
rc=$?

check "picker exits 0 despite polluted create JSON" 0 $rc

grep -qF -- "--path $wt --label brand-new" "$state/herdr-calls" 2>/dev/null
check "worktree registered with the recovered path" 0 $?

grep -qF -- "GREN_HERDR_WORKTREE=$wt" "$state/herdr-calls" 2>/dev/null
check "setup pane opened for the recovered worktree" 0 $?

if [[ $fail -ne 0 ]]; then
  printf '\n--- picker output ---\n'
  cat "$state/picker-out" 2>/dev/null
  printf '\n--- herdr calls ---\n'
  cat "$state/herdr-calls" 2>/dev/null || echo "(none)"
  printf '\nsome picker tests FAILED\n'
else
  printf '\nall picker tests passed\n'
fi
exit $fail
