---
name: issue-worktrees
description: Use when the user starts work on an issue or ticket in a repo that uses gren worktrees — "we're fixing ABC-123", "let's take ABC-123", in any language — or explicitly asks to create or remove a worktree ("create a worktree for #123", "clean up, remove the worktree"). Applies whenever the gren CLI is available, with or without herdr (HERDR_ENV=1).
---

# Issue worktrees (gren + herdr)

Chat-driven equivalent of the gren-herdr plugin's pickers (`prefix+shift+g` create / `prefix+shift+d` remove): derive the branch name from the issue, create or remove with gren, keep herdr's sidebar in sync.

**REQUIRED BACKGROUND:** the `gren` skill (create flags, hook caveats, herdr registration) and the `herdr` skill (CLI). This skill only adds the issue→branch naming and the create/remove orchestration.

## When this fires

The user announcing that work on an issue is starting — "we're fixing ABC-123", "let's take ABC-123" — IS the trigger; they will usually not say the word "worktree". In a gren-managed repo (a `.gren/` dir, or `gren list` works), create the issue's worktree **first**, before planning, brainstorming, or exploration skills take over, so everything that follows happens inside it — never implement an issue on the main checkout. If the issue can't be found in the tracker, stop and ask before creating anything. Analysis-only questions ("what's in ABC-123?", "which issues exist?") don't need a worktree.

## Create — "we're fixing ABC-123, create a worktree"

1. **Derive the branch name**, in priority order:
   - **Linear issue mentioned** (e.g. `ABC-123`): fetch it (Linear MCP `get_issue`) and use its `gitBranchName` **verbatim**. It is the canonical name that auto-links branch↔issue in Linear — don't shorten or re-slug it.
   - **GitHub issue** `#123`: `gh issue view 123 --json title,labels` → `feat/123-short-slug` or `fix/123-short-slug` (pick prefix from the issue type/labels; slug from the title, ≤5 words).
   - **No issue reference**: `feat/<short-slug>` from the task description; confirm the name with the user if the task is vague.
2. **Create from the main checkout** (never from inside another worktree — gren reads `.gren/config.toml` relative to cwd):
   ```bash
   gren create -n "<branch>" --format=json --no-hooks
   ```
   Parse `.path` from the JSON. `--no-hooks` is unconditional and mirrors the create picker: post-create runs as its own step (4) where output is visible and prompts reach a TTY. It is a deferral, never a skip.
3. **Register in herdr's sidebar** (only if `HERDR_ENV=1`):
   ```bash
   herdr worktree open --path "<path>" --cwd "<main repo>" --no-focus --json
   herdr workspace rename <workspace-id> "<branch>"
   ```
   Parse `<workspace-id>` from `worktree open`'s JSON output. **Rename to the branch name — the exact string passed to `gren create -n`, slashes and all** (`fix/123-short-slug`, `<user>/abc-123-short-slug`). Not the bare issue id: `#123` / `ABC-123` throws away the type prefix and the slug, which is the whole point of the label.

   herdr already labels the workspace with the worktree's directory basename (`fix-123-short-slug`) — that default is *fine*, just slash-less. Read the `.workspace.label` you get back from `worktree open` before renaming; if it already reads as the branch, skip the rename rather than replacing a good label with a worse one. Keep `--no-focus` unless the user asked to jump into the worktree.

4. **Run post-create setup.** Required whenever `.gren/config.toml` defines a `post-create` hook — the worktree is not ready to hand over until it has run. First check whether the hook is interactive: `interactive = true` on a `[[named-hooks.post-create]]` entry, or the script itself prompting (`read`, y/N). Many op/seed hooks are deliberately non-interactive — desktop-app `op` works headless — so check, don't assume.
   - **In herdr**: run it in the worktree's root pane (`.result.root_pane.pane_id` from `worktree open`), with an exit-code sentinel appended:
     ```bash
     herdr pane run <pane_id> "gren hook-run --type post-create --path '<path>' --branch '<branch>' --base '<base-branch>'; echo SETUP-EXIT-\$?"
     herdr pane wait-output <pane_id> --regex 'SETUP-EXIT-[0-9]+' --timeout 600000
     ```
     `SETUP-EXIT-0` = success; anything else → read the pane tail and report the failure. This is the **only** sanctioned way to wait: do not poll `pane read | grep` for prompt glyphs or guessed completion phrases — gren prints no terminal marker on success (just ✓-lines, then the shell prompt returns), and prompt symbols vary per user config, so glyph-scraping loops hang forever. The sentinel is prompt-agnostic; keep the `-[0-9]+` requirement so the match can't hit the command's own echo (which shows the literal `$?`).

     > **herdr ≤ 0.7.4**: the waiter lived at the top level and took the pattern differently — `herdr wait output <pane_id> --regex --match 'SETUP-EXIT-[0-9]+' --timeout 600000`. 0.7.5 moved it under `pane` and made `--regex` take the pattern as its value. Probe with `herdr pane wait-output --help >/dev/null 2>&1` if you must support both.

     `--interactive` is **gren's** flag, on the `hook-run` command inside the quoted string — add it only when the hook is interactive, then tell the user the pane is waiting for their input (an approval prompt is part of `--interactive`) and wait on the sentinel the same way, with a generous timeout. It is *not* a herdr flag: `herdr pane run` takes no options at all (`herdr pane run <PANE_ID> <COMMAND>...`), so a stray `--interactive` there is parsed as the pane id and fails with `pane_not_found`. Verify the command actually submitted — long strings can stall as a paste placeholder.

     **`pane run` types into whatever is running in that pane.** It is only safe while the pane is still a shell. If any time has passed since `worktree open` (or you are re-entering the flow), check `herdr pane process-info <pane_id>` first — if the user has already started an agent or another program there, your "command" becomes a prompt fed to it. Run setup immediately after `worktree open`, before handing the worktree over.
   - **Not in herdr**: non-interactive hook → run the same `gren hook-run` directly from the worktree. Interactive hook → give the user the exact command; that is the only case where setup is handed off.

   Setup may be skipped only when the user explicitly says to skip it — then say so when reporting, so a later build failure isn't a mystery.

5. **Hand the worktree over to an agent** (herdr ≥ 0.7.5, and only when the user wants the work to continue in that pane rather than in yours). After `SETUP-EXIT-0` the pane is back at its shell prompt, which is exactly what `agent start` requires:
   ```bash
   herdr agent start "<repo>/<branch>" --kind claude --pane <pane_id>
   herdr agent prompt "<repo>/<branch>" "<issue title + link + what to do>" --wait
   ```
   Prefer this over `pane run "claude"` + output-scraping. `agent start` verifies the pane is at an interactive prompt, validates the agent kind, and only reports success once the agent is detected and ready for input — so it fails loudly instead of typing your command into whatever else is running there. `agent prompt --wait` returns `agent_prompt_stalled` after five seconds without an observed state change, instead of hanging on a submission that never landed.

   **Name it `<repo>/<branch>`, not `<branch>`.** The name must be unique among *live* agents, and branch names collide across repos in one herdr session. Names are live-only — they are cleared when the agent exits, is released, or is replaced — so re-read them from `herdr agent list` rather than assuming yours survived. Once named, every later `agent read/prompt/wait/focus` takes that name instead of a pane id, which stays correct after the pane is moved or the ids compact.

## Remove — "we're done with ABC-123, remove the worktree"

**Inside herdr (`HERDR_ENV=1`): invoke the plugin's remover — the same thing the `prefix+shift+d` keybinding runs.** It opens a pane with a picker and gren's own y/N confirmation on a real TTY, runs pre-remove hooks, and closes the sidebar workspace itself:

```bash
herdr plugin action invoke remove --plugin gren
```

Then tell the user which branch to pick in the picker. Don't replicate the flow with `gren delete -f` when the pane is available — `-f` skips gren's confirmation **and force-deletes a dirty worktree, uncommitted files included**; the pane keeps the human gating the destructive step.

**Fallback — when the picker can't be used**: not inside herdr, the gren plugin isn't installed, or nobody is at the keyboard to drive the picker (autonomous cleanup, or the user asked for hands-off removal). An agent can't answer gren's y/N prompt, so `-f` is required; the gates around it are therefore mandatory:

1. **Safety gate — uncommitted work**: `git -C <worktree> status --porcelain` must be empty. Otherwise stop and show the user what's uncommitted — never resolve it with force-delete, `git clean`, or stashing on their behalf.
2. **Safety gate — live agent** (in herdr): a clean tree does not mean nobody is working there. An agent mid-turn has nothing on disk yet.
   ```bash
   herdr agent list | jq -r --arg p "<path>" \
     '.result.agents[] | select(((.foreground_cwd // .cwd) // "") | startswith($p)) | "\(.name // .pane_id) \(.agent_status)"'
   ```
   Any hit with status `working` or `blocked` → stop and ask. `idle`/`done` is fine to remove.
3. **If in herdr, capture the workspace id** while the path still exists:
   ```bash
   herdr worktree list --cwd "<main repo>" --json \
     | jq -r --arg p "<path>" '.result.worktrees[] | select(.path==$p) | .open_workspace_id // empty'
   ```
4. **Delete from the main checkout**, only after steps 1 and 2 passed:
   ```bash
   gren delete -f -- "<branch>"
   ```
5. **Close the sidebar workspace** if one was found: `herdr workspace close <workspace-id>`.

**Either path: keep the branch.** gren preserves it by design. Delete it only if the user asked, or it has zero unique commits vs. its base — then `git branch -d` (never `-D`).

## Common mistakes

| Mistake | Fix |
|---|---|
| Inventing a branch name for a Linear issue | Use `gitBranchName` from `get_issue`, verbatim |
| Labelling the herdr workspace `#123` / `ABC-123` | Label with the **branch name**. The bare issue id drops the type prefix and slug, and is *worse* than herdr's own directory-basename default |
| Running `gren create`/`gren delete` from inside a worktree | `cd` to the main checkout first — worktree cwd hands gren a stale (or vanishing) `.gren` config |
| Removing with `gren delete -f` while inside herdr | Invoke the plugin's remover instead — `-f` bypasses gren's confirmation and dirty-worktree refusal |
| Worktree deleted but its workspace still in the sidebar (fallback path) | Capture `open_workspace_id` before deleting, `herdr workspace close` after |
| Force-handling a dirty worktree | Stop and show the user; they decide |
| Deleting the branch along with the worktree | Branch stays unless the user says otherwise |
| Creating with `--no-hooks` and telling the user to run setup themselves | `--no-hooks` defers setup to step 4; the agent runs `gren hook-run` (in the herdr pane when available) |
| Assuming hooks "need a TTY" without checking | Interactivity is observable: `interactive = true` in config, or `read`/prompts in the script. Only interactive hooks need `--interactive` and a human |
| Waiting for setup by polling `pane read \| grep` for prompt glyphs or guessed phrases ("completed", `❯ $`) | Append `; echo SETUP-EXIT-\$?` to the command and `herdr pane wait-output <pane_id> --regex 'SETUP-EXIT-[0-9]+'` — gren has no success marker and prompt glyphs vary, so scraping hangs forever |
| `herdr wait output …` | Removed in 0.7.5. The waiters are now `herdr pane wait-output <pane_id> --regex '<pattern>'` and `herdr agent wait <target> --until <status>`. `--regex` takes the pattern; there is no separate `--match` alongside it |
| `pane run` into a pane without checking what's running there | `pane run` types into the foreground program. After handoff the user may have an agent in that pane — your command becomes its prompt. Check `herdr pane process-info` unless you *just* opened the pane |
| Starting an agent with `pane run "claude"` and scraping for a prompt glyph | `herdr agent start <name> --kind claude --pane <id>` — it requires a shell prompt, validates the kind, and succeeds only once the agent is detected and ready |
| Naming the agent just `<branch>` | Agent names must be unique among live agents, and branches collide across repos in one session. Use `<repo>/<branch>` |
| Removing a worktree because `git status` is clean | A running agent has nothing on disk yet. Check `herdr agent list` for `working`/`blocked` under that path first |
