#!/usr/bin/env bash
# Run every test in this directory. Exit non-zero if any suite fails.
#   bash tests/run.sh
#
# Suites split into two kinds:
#   *_test.sh with stubbed gren/herdr — verify this plugin's control flow.
#   contract_test.sh — runs the REAL binaries, verifying our assumptions about
#     gren/herdr still hold. It SKIPS (green) when a binary is absent, so it is
#     safe in CI without the tools installed.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fail=0

for t in "$here"/helpers_test.sh "$here"/picker_test.sh \
         "$here"/bootstrap_test.sh "$here"/contract_test.sh; do
  [[ -f $t ]] || continue
  printf '\n\033[1m=== %s ===\033[0m\n' "$(basename "$t")"
  if ! bash "$t"; then
    fail=1
  fi
done

printf '\n'
if [[ $fail -eq 0 ]]; then
  printf '\033[32mall suites passed\033[0m\n'
else
  printf '\033[31msome suites FAILED\033[0m\n'
fi
exit $fail
