#!/usr/bin/env bash
# The other suites stub gren/herdr and test control flow. Nothing reads SKILL.md,
# so a rule can be deleted from the skill and every suite stays green.
#
# This file guards the rules whose absence has already cost a run. Keep it to
# invariants with an incident behind them, not a spellcheck of the prose.
#
# Assertions are written as if/then/else, never `cond && ok || bad`: the && || form
# runs the failure branch whenever the success branch returns non-zero, so a suite
# written that way can report a failure it did not have. Shellcheck flags it (SC2015)
# and CI runs shellcheck, so the short form also breaks the build.
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

if grep -q 'does not load' <<<"$step6"; then
  ok "step 6 states that a named-only skill does not load"
else
  bad "step 6 lost the named-only-skill rule"
fi

# The example must put the skill BEFORE the brief. Order is the whole point:
# an example with the brief first teaches exactly the bug this rule exists for.
# shellcheck disable=SC2016  # a regex, and \$brief is matched literally in the doc
if grep -qE 'prompt=.*printf.*"/[a-z:-]+".*"\$brief"' <<<"$step6"; then
  ok "the worked example leads with the skill token, brief second"
else
  bad "the worked example no longer shows skill-first ordering"
fi

# --- the handover must wait for the receipt, not the turn --------------------------
# flyt#2419, 2026-09-02: step 6 prescribed `--wait --timeout 600000`. Bare --wait
# waits for the first *settled* state, i.e. the agent's whole first turn — but step 6
# is the last step, so nothing downstream reads it. Nine minutes of the orchestrator
# frozen in a tool call over an agent that was healthy and eleven minutes into the
# work. The skill had already seen this in 2026-08-18 and concluded "pass a bigger
# --timeout", which lengthens the hang. Assert the command, not the prose: a
# regression here is silent and costs the user minutes every hand-off.
cmd="$(grep -m1 'herdr agent prompt' <<<"$step6")"
[ -n "$cmd" ] || bad "step 6 lost its 'herdr agent prompt' example"

if grep -q -- '--until working' <<<"$cmd"; then
  ok "the handover overrides the settled set with --until working"
else
  bad "the handover example blocks on the default settled set (idle/done/blocked)"
fi

# Above 5000, or a submission that never landed degrades from agent_prompt_stalled to
# a bare timeout; anywhere near the old 600000 and we are back to waiting out the turn.
ms="$(grep -oE -- '--timeout [0-9]+' <<<"$cmd" | grep -oE '[0-9]+')"
if [ -n "$ms" ] && [ "$ms" -gt 5000 ] && [ "$ms" -le 60000 ]; then
  ok "handover --timeout is ${ms}ms: above the stalled guard, far below a turn"
else
  bad "handover --timeout is '${ms:-missing}' — want >5000 (stalled guard) and <=60000"
fi

# --- positive control -------------------------------------------------------------
# Without this, every assertion above passes on an empty or truncated file and the
# suite reports green on a skill that says nothing.
lines=$(wc -l < "$skill" | tr -d ' ')
if [ "$lines" -gt 120 ]; then
  ok "denominator: SKILL.md is $lines lines, not a stub"
else
  bad "SKILL.md is only $lines lines — assertions above are vacuous"
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "ERROR: no assertions ran" >&2; exit 1; }
[ "$fail" -eq 0 ]
