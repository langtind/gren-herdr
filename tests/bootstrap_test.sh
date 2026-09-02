#!/usr/bin/env bash
# Tests for bootstrap.sh — the setup-pane process. Run: bash tests/bootstrap_test.sh
#
# These STUB gren/herdr, so (like picker_test.sh) they verify this script's own
# control flow — argument plumbing and ordering — NOT that the flags are real.
# The real-flag guarantee lives in contract_test.sh, which runs the installed
# binaries. Keep that split in mind: a green run here means "bootstrap.sh calls
# herdr the way we intend", not "herdr accepts these flags".
#
# Focus: the port-metadata block. It must badge the pane with a port=<n> token AND
# report the same token on the workspace, resolving the workspace via `herdr pane
# get`. Both are best-effort and must never make the script fail.
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

# A real worktree so bootstrap.sh can cd into it and resolve the branch.
repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email t@e.com
git -C "$repo" config user.name T
printf 'x\n' >"$repo/f"
git -C "$repo" add -A
git -C "$repo" commit -qm init
wt="$work/wt"
git -C "$repo" worktree add -q -b feat/x "$wt" >/dev/null 2>&1

stubs="$work/stubs"; state="$work/state"; mkdir -p "$stubs" "$state"

# gren stub: hash_port yields a fixed port; hook-run no-ops success; list unused.
cat >"$stubs/gren" <<STUB
#!/usr/bin/env bash
case "\$1" in
  step) printf '4242\n' ;;                         # {{ branch | hash_port }}
  hook-run) printf 'hook-run %s\n' "\$*" >>"$state/gren-calls" ;;
esac
exit 0
STUB

# herdr stub: records each invocation; `pane get` answers with the workspace id so
# the script can resolve a target workspace. Rejects --custom-status the way every
# supported herdr does — the flag was replaced by --token in 0.7.4 and 0.7 is no
# longer supported, so a call carrying it is a bug, not a fallback.
cat >"$stubs/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$state/herdr-calls"
if [[ "\$1" == "pane" && "\$2" == "get" ]]; then
  printf '{"result":{"pane":{"workspace_id":"wsX"}}}\n'
fi
if [[ "\$*" == *--custom-status* ]]; then
  echo "unknown option: --custom-status" >&2; exit 2
fi
exit 0
STUB
chmod +x "$stubs/gren" "$stubs/herdr"

PATH="$stubs:$PATH" HERDR_BIN_PATH="$stubs/herdr" HERDR_PLUGIN_ID=gren \
  GREN_HERDR_WORKTREE="$wt" GREN_HERDR_BRANCH="feat/x" \
  GREN_HERDR_REPO_ROOT="$repo" GREN_HERDR_TARGET_PANE="paneZ" \
  bash "$here/../bootstrap.sh" </dev/null >"$state/out" 2>&1
check "bootstrap exits 0" 0 $?

# 1. Pane badge goes through --token; the stub rejects --custom-status.
grep -qF -- "pane report-metadata paneZ --source gren --token port=4242" "$state/herdr-calls"
check "pane badge reported with --token" 0 $?

# 1b. And --custom-status is never attempted. The 0.7.3 fallback was removed with
# 0.7 support; re-adding it would send a flag no supported herdr accepts.
if ! grep -q -- "--custom-status" "$state/herdr-calls"; then
  printf 'ok: no --custom-status fallback attempted\n'
else
  printf 'FAIL: bootstrap still falls back to --custom-status\n'; fail=1
fi

# 2. Workspace resolved via pane get, using the target pane.
grep -qF -- "pane get paneZ" "$state/herdr-calls"
check "workspace resolved from the target pane" 0 $?

# 3. Workspace port token — reported on the resolved workspace.
grep -qF -- "workspace report-metadata wsX --source gren --token port=4242" "$state/herdr-calls"
check "workspace port token reported" 0 $?

# 4. Setup still runs: gren hook-run is invoked for the worktree.
grep -qF -- "hook-run --type post-create" "$state/gren-calls"
check "gren post-create hook still runs" 0 $?

# --- resilience: a broken `pane get` must not skip the badge or fail the run ---
: >"$state/herdr-calls"
cat >"$stubs/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$state/herdr-calls"
# pane get returns garbage (no workspace_id) — the workspace report must give up
# quietly, and the script must still finish.
if [[ "\$1" == "pane" && "\$2" == "get" ]]; then printf 'not json\n'; fi
exit 0
STUB
chmod +x "$stubs/herdr"

PATH="$stubs:$PATH" HERDR_BIN_PATH="$stubs/herdr" HERDR_PLUGIN_ID=gren \
  GREN_HERDR_WORKTREE="$wt" GREN_HERDR_BRANCH="feat/x" \
  GREN_HERDR_REPO_ROOT="$repo" GREN_HERDR_TARGET_PANE="paneZ" \
  bash "$here/../bootstrap.sh" </dev/null >"$state/out2" 2>&1
check "bootstrap still exits 0 when pane get returns garbage" 0 $?

grep -qF -- "pane report-metadata paneZ --source gren --token port=4242" "$state/herdr-calls"
check "pane badge still reported despite unresolvable workspace" 0 $?

if ! grep -q -- "workspace report-metadata" "$state/herdr-calls"; then
  printf 'ok: no workspace token reported when workspace is unresolvable\n'
else
  printf 'FAIL: reported a workspace token with no resolved workspace id\n'; fail=1
fi

if [[ $fail -ne 0 ]]; then
  printf '\n--- herdr calls ---\n'; cat "$state/herdr-calls" 2>/dev/null
  printf '\n--- output ---\n'; cat "$state/out" 2>/dev/null
  printf '\nsome bootstrap tests FAILED\n'
else
  printf '\nall bootstrap tests passed\n'
fi
exit $fail
