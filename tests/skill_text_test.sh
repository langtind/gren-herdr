#!/usr/bin/env bash
# The other suites stub gren/herdr and test control flow. Nothing reads SKILL.md,
# so a rule can be deleted from the skill and every suite stays green.
#
# This file guards the rules whose absence has already cost a run. Keep it to
# invariants with an incident behind them, not a spellcheck of the prose.
set -uo pipefail
skill="$(cd "$(dirname "$0")/.." && pwd)/skills/issue-worktrees/SKILL.md"
pass=0 fail=0
ok()  { printf 'ok: %s\n' "$1";   pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

[ -f "$skill" ] || { echo "FAIL: no SKILL.md at $skill" >&2; exit 1; }

# --- the prompt must LEAD with the skill ------------------------------------------
# VID-945, 2026-09-01: a brief that said "Bruk /vidd-tdd" and a hook that said
# "invoke pstack:poteto-mode" both lost. 19 Bash calls, 0 Skill calls. Naming a
# skill in prose is a suggestion; a leading /skill token is expanded by the harness.
step6="$(sed -n '/The first prompt is the user/,/^## Remove/p' "$skill")"
[ -n "$step6" ] || bad "step 6 not found — did the heading change?"

printf '%s' "$step6" | grep -q 'does not load' \
  && ok "step 6 states that a named-only skill does not load" \
  || bad "step 6 lost the named-only-skill rule"

# The example must put the skill BEFORE the brief. Order is the whole point:
# an example with the brief first teaches exactly the bug this rule exists for.
if printf '%s' "$step6" | grep -qE 'prompt=.*printf.*"/[a-z:-]+".*"\$brief"'; then
  ok "the worked example leads with the skill token, brief second"
else
  bad "the worked example no longer shows skill-first ordering"
fi

# --- positive control -------------------------------------------------------------
# Without this, every assertion above passes on an empty or truncated file and the
# suite reports green on a skill that says nothing.
lines=$(wc -l < "$skill")
[ "$lines" -gt 120 ] \
  && ok "denominator: SKILL.md is $lines lines, not a stub" \
  || bad "SKILL.md is only $lines lines — assertions above are vacuous"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "ERROR: no assertions ran" >&2; exit 1; }
[ "$fail" -eq 0 ]
