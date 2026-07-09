# Debugging gren-in-herdr

A field guide for diagnosing issues in the gren ↔ herdr integration. Written from
hard-won dogfooding — most of these techniques exist because the "obvious" test
(a single, non-interactive `go test`) missed the real bug.

## How the pieces fit

- **gren** — the worktree manager (a Go binary on `PATH`). Runs hooks, resolves
  paths, manages config.
- **herdr** — the terminal multiplexer. Creates worktrees (native dialog / CLI),
  opens panes, emits lifecycle events, exposes a socket API (`herdr pane …`).
- **gren-herdr** (this plugin) — a manifest + bash scripts. It does **not** manage
  worktrees itself; it reacts to herdr events and shells out to `gren`.

The plugin only glues. When something misbehaves, first decide **whose** bug it is:
gren (hook logic, path resolution), herdr (event payload, pane rendering), or the
plugin (the bash in between).

## Two creation paths (they behave differently)

| | Native "New worktree" (sidebar / right-click / `prefix+shift+g` dialog) | gren picker (`prefix+shift+g` → `gren.open`) |
|---|---|---|
| Who creates the worktree | herdr | `gren create --no-hooks` |
| Location | `~/.herdr/worktrees/<repo>/<branch>` | gren's configured `worktree_dir` |
| Base branch | herdr picks (the workspace's current HEAD) | you choose in the picker (default main/master) |
| Trigger to run setup | `worktree.created` event → `on-created.sh` | `picker.sh` opens the bootstrap pane directly |

Both then open the **bootstrap pane** → `gren hook-run --type post-create --interactive`.
"base: ?" in the bootstrap output is expected: herdr's event carries no base branch.

## Event model

- Plugin subscribes to **`worktree.created`** only (see `herdr-plugin.toml`).
- herdr also emits `worktree.opened` and `worktree.removed`, but the plugin ignores
  them. There is **no** `worktree.removing` (before-delete) event.
- Consequence: **native sidebar delete runs no gren removal hooks** — use
  `prefix+shift+d` (`gren.remove` → `gren delete`, which runs pre/post-remove while
  the worktree still exists). See the "Removing worktrees" section in the README.

## Debugging workflow

### 1. Test a gren fix without cutting a release

Build locally and swap it in over the brew binary so herdr's shells + the plugin
use it. **Validate the real herdr flow before releasing.**

```bash
cd ~/Developer/Private/gren
go build -o /tmp/gren-dev .
rm -f /opt/homebrew/bin/gren && cp /tmp/gren-dev /opt/homebrew/bin/gren && chmod +x /opt/homebrew/bin/gren
command /opt/homebrew/bin/gren --version    # confirm your build is live

# … test in herdr …

brew reinstall gren && brew link --overwrite gren   # restore official binary
```

Note: replacing the symlink with a real file means `brew reinstall` won't re-link
on its own — `brew link --overwrite gren` fixes it.

### 2. Reproduce TTY-only bugs with a PTY

Several bugs only fire when **stdin/stdout is a terminal** (interactive shells) or
under **concurrency** — a plain `go test` (no TTY, single process) sails right past
them. Give a command a pseudo-terminal:

```bash
# Reproduce what an interactive shell sees, e.g. eval "$(gren shell-init zsh)":
script -q /dev/null zsh -fc 'eval "$(gren shell-init zsh)" && echo OK'

# Give any gren command a TTY on stdin/stdout:
script -q /dev/null gren hook-run --type post-create --path "$WT" --branch b --interactive
```

To reproduce inside a repo whose config needs migration, hand-write an old version:
`printf 'version = "1.0.0"\n…\n' > .gren/config.toml`.

### 3. Inspect a worktree's shell from outside

```bash
herdr pane list            # find the pane whose cwd is the worktree
herdr pane read <pane_id> --source visible --lines 40
herdr pane read <pane_id> --source recent-unwrapped --lines 40
```

Use this to confirm a worktree shell is clean (no `(eval)` errors / panics) after a
create.

### 4. Isolate the approval store

Hook approvals persist per project under the data dir. To test approval behaviour
without polluting the real store (or to reproduce a fresh, unapproved state), set a
throwaway `XDG_DATA_HOME`:

```bash
export XDG_DATA_HOME=$(mktemp -d) HOME=$(mktemp -d)
```

## Failure-signature table

| Symptom | Cause | Fixed in |
|---|---|---|
| `(eval):1: unknown file attribute: v` / `(eval):2: no matches found: config?` in a worktree shell on create | gren's config-migration prompt printed to stdout during `gren shell-init zsh`, then eval'd by `.zshrc`'s `eval "$(gren shell-init zsh)"` | gren 0.16.1 (migration prompt is now TUI-only) |
| `panic … nil pointer … main.checkAndPromptMigration` | concurrent gren processes race migrating the config; `Migrate()` returns `(nil,nil)` and the caller dereferenced it | gren 0.16.1 |
| Post-create script's `.env` symlink (or anything using `$REPO_ROOT`) silently missing | `gren hook-run` from a worktree resolved `$REPO_ROOT` to the worktree, not the main checkout | gren 0.16.0 (`getRepoRoot` uses `git --git-common-dir`) |
| Approval prompt appears for **every** new worktree, even after choosing "always" | `GetProjectID()` returned `os.Getwd()` → a different ID per worktree | gren 0.16.2 (remote URL → main worktree root) |
| Bootstrap pane blank until you press a key / click | pane opened `--no-focus`; herdr doesn't paint/route input to an unfocused split | gren-herdr `59a892f` (setup pane opens `--focus`) |
| `direnv: unloading` on every worktree shell | herdr inherited stale `DIRENV_*` env from its launch dir — benign, cosmetic | (not a gren bug) |
| "Press Enter to finish setup" in the test repo | the **test repo's** `post-create.sh` has an artificial `read` prompt to demo TTY — not the plugin | (test artifact) |
| Fresh picker-created worktree left **with no setup at all** — no `.gren-ports`/env symlinks/deps/DBs, no `hook-run` in `gren logs`, no event file in gren's events dir | picker creates with `--no-hooks`, then `herdr worktree open` (sidebar registration) failed client-side — its stderr was discarded (`2>/dev/null`) so the cause was unrecoverable — and the picker aborted **before** the setup pane; the inline fallback only covered pane-open failures, not registration failures | gren-herdr `3924cf1` (stderr kept + `hook-run --interactive` runs inline in the picker pane on registration failure) |
| `make seed` / any `op`-gated setup **silently skipped** on worktree create inside herdr — DBs migrated but empty (no seed data) | the consumer repo's `post-create.sh` gated the step on `op whoami`, a **false negative** under 1Password desktop integration (no CLI session token; per-command TouchID) and *always* non-zero inside herdr, whose launchd-reparented server loses macOS responsible-process attribution ([herdr#808](https://github.com/ogulcancelik/herdr/issues/808)) so 1Password never persists "Always Allow". `op run` (what `make seed` uses) still works | consumer hook, not gren/plugin — don't gate on `op whoami`; attempt the step and treat op failure as non-fatal. Reference fix: flyt `.gren/post-create.sh` ([agensdev/flyt#1282](https://github.com/agensdev/flyt/pull/1282)) |

## Recurring gotchas

- **cwd matters for gren.** `getRepoRoot`, `getCurrentBranch`, `getDefaultBranch`,
  `GetProjectID` all run git in the process cwd. The bootstrap pane's cwd is the
  worktree, so anything that must be repo-wide has to resolve the **main** worktree
  (via `git --git-common-dir`), not `--show-toplevel`.
- **Config gets normalized.** gren rewrites `.gren/config.toml` (e.g. version bump)
  on some operations. A worktree checks out the *committed* config, so an old
  committed version can differ from the main checkout's working copy.
- **Approvals are keyed on the command string.** Editing a hook command in config
  invalidates its approval; the next run re-prompts. That's expected.
- **Grep for the right thing.** When a shell shows garbage, check for `panic` too,
  not just the visible error text — a crashing gren command can surface as
  downstream `(eval)`/`source` errors. (This mislead the first diagnosis of the
  migration bug.)
