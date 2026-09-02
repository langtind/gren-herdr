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

# Glob, never a hardcoded list. A named list silently skips a suite someone adds
# later, and reports green while doing it — the runner counted 4 of 5 on 2026-09-01,
# which is true and misleading at the same time. contract_test.sh runs last because
# it touches the real binaries; the rest are order-independent.
mapfile -t suites < <(
  find "$here" -maxdepth 1 -name '*_test.sh' ! -name 'contract_test.sh' | sort
  [[ -f "$here/contract_test.sh" ]] && printf '%s\n' "$here/contract_test.sh"
)
(( ${#suites[@]} )) || { printf '\033[31mERROR: no *_test.sh suites found\033[0m\n'; exit 1; }

for t in "${suites[@]}"; do
  [[ -f $t ]] || continue
  printf '\n\033[1m=== %s ===\033[0m\n' "$(basename "$t")"
  if ! bash "$t"; then
    fail=1
  fi
done

printf '\n'
if [[ $fail -eq 0 ]]; then
  printf '\033[32mall %s suites passed\033[0m\n' "${#suites[@]}"
else
  printf '\033[31msome suites FAILED\033[0m\n'
fi
exit $fail
