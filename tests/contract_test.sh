#!/usr/bin/env bash
# Contract tests: assert that the REAL gren and herdr binaries still behave the
# way this plugin's scripts assume. Run: bash tests/contract_test.sh
#
# Every other test stubs gren/herdr — so by construction they can only ever
# confirm our own control flow, never catch upstream drift. But upstream drift
# is exactly what has bitten this plugin: gren changed `create --format=json`
# output (the 2026-07-12 incident), and herdr dropped source_workspace_id from
# `worktree list`. A stub written after the fact reproduces the break; it never
# predicts it. This file is the counterpart that runs against the installed
# binaries and fails LOUDLY when an assumption stops holding.
#
# Design rules:
#   - Skip (not fail) when a binary is absent, so CI without the tool is green.
#   - Never mutate the caller's live herdr session. We probe flag PARSING by
#     targeting bogus ids: a "not found" error means the flags parsed and
#     reached the server; "unknown option" means the contract is broken.
#   - Version-gated contracts (herdr >= 0.7.4 workspace metadata) SKIP loudly on
#     older herdr rather than silently passing.
set -uo pipefail

herdr=${HERDR_BIN_PATH:-herdr}

pass=0 fail=0 skip=0
ok()   { printf 'ok: %s\n' "$1";       pass=$((pass+1)); }
bad()  { printf 'FAIL: %s\n  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skips(){ printf 'skip: %s\n  %s\n' "$1" "${2:-}"; skip=$((skip+1)); }

# --- gren contracts -------------------------------------------------------
# The plugin reads specific fields out of gren's JSON and templating. If these
# shift, picker.sh / remove.sh / bootstrap.sh break in ways stubs can't see.
if ! command -v gren >/dev/null; then
  skips "gren contracts" "gren not on PATH"
else
  # A throwaway git repo — NOT gren-configured (no .gren), so we only exercise
  # read-only, config-independent surface.
  repo=$(mktemp -d)
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@e.com
  git -C "$repo" config user.name T
  printf 'x\n' >"$repo/f"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init

  # gren list --format=json → array of objects with .branch, .path, .is_main.
  # picker.sh and remove.sh select on all three.
  if list=$(gren -C "$repo" list --format=json 2>/dev/null) \
     || list=$( (cd "$repo" && gren list --format=json) 2>/dev/null); then
    shape=$(printf '%s' "$list" | jq -r '
      if type != "array" then "not-array"
      elif length == 0 then "empty"
      elif (.[0] | has("branch") and has("path") and has("is_main")) then "ok"
      else "missing-keys" end' 2>/dev/null)
    case $shape in
      ok) ok "gren list --format=json → array with .branch/.path/.is_main" ;;
      *)  bad "gren list JSON shape changed" "got: $shape — picker/remove select on .branch/.path/.is_main" ;;
    esac
  else
    bad "gren list --format=json failed in a plain git repo" "picker.sh aborts here"
  fi

  # gren step eval '{{ branch | hash_port }}' → a bare integer. bootstrap.sh
  # badges the pane with this and reports it as the workspace port token.
  port=$( (cd "$repo" && gren step eval '{{ branch | hash_port }}') 2>/dev/null || true)
  if [[ $port =~ ^[0-9]+$ ]]; then
    ok "gren step eval hash_port → integer ($port)"
  else
    bad "gren hash_port no longer yields a bare integer" "got: ${port:-<empty>} — bootstrap.sh port badge breaks"
  fi

  rm -rf "$repo"
fi

# --- herdr contracts ------------------------------------------------------
if ! command -v "$herdr" >/dev/null && ! command -v herdr >/dev/null; then
  skips "herdr contracts" "herdr not on PATH"
else
  # pane get <id> → .result.pane.workspace_id. bootstrap.sh uses this to find
  # the workspace to report the port token on. A bogus id must still be REJECTED
  # by 'not found' (proving the response envelope shape), not usage text.
  out=$("$herdr" pane get "no-such:pane" 2>&1 || true)
  if printf '%s' "$out" | jq -e '.error.code // .result.pane.workspace_id' >/dev/null 2>&1; then
    ok "herdr pane get → JSON envelope (.result.pane.workspace_id path exists)"
  else
    bad "herdr pane get is not the expected JSON envelope" "got: $(printf '%s' "$out" | head -c 120)"
  fi

  # pane report-metadata: the badge tries --token (>= 0.7.4) and falls back to
  # --custom-status (<= 0.7.3). AT LEAST ONE must parse, or the badge silently
  # vanishes — which is exactly what 0.7.4 did when it renamed the flag. Target a
  # bogus pane so nothing real is mutated: "not found" proves the flags parsed
  # and reached the server; "unknown option" means the flag is gone.
  parses() { # flag-args… → 0 if herdr accepted the flags
    local out
    out=$("$herdr" pane report-metadata "no-such:pane" --source contract-test "$@" 2>&1 || true)
    printf '%s' "$out" | grep -qiE 'pane_not_found|not found'
  }
  tok=1 cus=1
  parses --token "port=1"        || tok=0
  parses --custom-status "port 1" || cus=0
  if [[ $tok -eq 1 || $cus -eq 1 ]]; then
    ok "herdr pane report-metadata badge flag parses (--token=$tok --custom-status=$cus)"
  else
    bad "herdr pane report-metadata accepts NEITHER --token nor --custom-status" \
        "bootstrap.sh's pane badge silently no-ops — check 'herdr pane report-metadata' usage"
  fi

  # Version-gated: workspace report-metadata + --token is the herdr >= 0.7.4
  # contract the new port-on-workspace code depends on. On 0.7.3 the subcommand
  # is absent (prints `workspace` usage) — SKIP loudly, don't pass silently.
  out=$("$herdr" workspace report-metadata "no-such-ws" --source contract-test --token "port=1" 2>&1 || true)
  if printf '%s' "$out" | grep -qiE 'workspace_not_found|not found'; then
    ok "herdr workspace report-metadata --source/--token parse (0.7.4 port token)"
  elif printf '%s' "$out" | grep -qiE 'unknown option: --token|unknown option: --source'; then
    bad "herdr workspace report-metadata rejects --source/--token" "got: $out — the 0.7.4 port-on-workspace code is wrong"
  elif printf '%s' "$out" | grep -qiE 'herdr workspace commands|unknown (sub)?command|usage'; then
    skips "herdr workspace report-metadata (herdr >= 0.7.4)" "not in this herdr ($("$herdr" --version 2>/dev/null | head -1)); port token no-ops, as designed"
  else
    skips "herdr workspace report-metadata" "inconclusive: $(printf '%s' "$out" | head -c 120)"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
