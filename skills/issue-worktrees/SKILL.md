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
   - **In herdr**: run it in the worktree's root pane (`.result.root_pane.pane_id` from `worktree open`):
     ```bash
     herdr pane run <pane_id> "gren hook-run --type post-create --path '<path>' --branch '<branch>' --base '<base-branch>'"
     ```
     Add `--interactive` only when the hook is interactive, and tell the user the pane is waiting for their input (an approval prompt is part of `--interactive`). Verify the command actually submitted — long strings can stall as a paste placeholder — and confirm completion before reporting the worktree ready.
   - **Not in herdr**: non-interactive hook → run the same `gren hook-run` directly from the worktree. Interactive hook → give the user the exact command; that is the only case where setup is handed off.

   Setup may be skipped only when the user explicitly says to skip it — then say so when reporting, so a later build failure isn't a mystery.

## Remove — "we're done with ABC-123, remove the worktree"

**Inside herdr (`HERDR_ENV=1`): invoke the plugin's remover — the same thing the `prefix+shift+d` keybinding runs.** It opens a pane with a picker and gren's own y/N confirmation on a real TTY, runs pre-remove hooks, and closes the sidebar workspace itself:

```bash
herdr plugin action invoke remove --plugin gren
```

Then tell the user which branch to pick in the picker. Don't replicate the flow with `gren delete -f` when the pane is available — `-f` skips gren's confirmation **and force-deletes a dirty worktree, uncommitted files included**; the pane keeps the human gating the destructive step.

**Fallback — when the picker can't be used**: not inside herdr, the gren plugin isn't installed, or nobody is at the keyboard to drive the picker (autonomous cleanup, or the user asked for hands-off removal). An agent can't answer gren's y/N prompt, so `-f` is required; the gates around it are therefore mandatory:

1. **Safety gate**: `git -C <worktree> status --porcelain` must be empty. Otherwise stop and show the user what's uncommitted — never resolve it with force-delete, `git clean`, or stashing on their behalf.
2. **If in herdr, capture the workspace id** while the path still exists:
   ```bash
   herdr worktree list --cwd "<main repo>" --json \
     | jq -r --arg p "<path>" '.result.worktrees[] | select(.path==$p) | .open_workspace_id // empty'
   ```
3. **Delete from the main checkout**, only after step 1 passed:
   ```bash
   gren delete -f -- "<branch>"
   ```
4. **Close the sidebar workspace** if one was found: `herdr workspace close <workspace-id>`.

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
