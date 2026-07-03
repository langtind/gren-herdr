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

if [[ $fail -eq 0 ]]; then
  printf '\nall helper tests passed\n'
else
  printf '\nsome helper tests FAILED\n'
fi
exit $fail
