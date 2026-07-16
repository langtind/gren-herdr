# gren

A [herdr](https://herdr.dev) plugin for creating, switching, and removing git
worktrees through [gren](https://github.com/langtind/gren) — so herdr worktrees
get gren's post-create setup: symlinked `.env*` files, dependency install,
direnv, and your project's lifecycle hooks.

## Why this plugin

herdr already ships its own worktree management (`herdr worktree
create/open/remove/list`), and it works fine. But herdr's built-in worktrees
have **no setup step** — a fresh checkout has no `.env`, no installed
dependencies, no bootstrapped services. gren is a dedicated worktree manager
built around exactly that: **lifecycle hooks** and smart project init
(package-manager detection, env-file symlinking, direnv, Claude config).

Rather than reimplement setup inside herdr, this plugin wires gren into herdr.
You get gren's hook-driven setup, while herdr multiplexes agents across the
resulting worktrees.

## What it does

**1. gren runs on every worktree herdr creates.** herdr emits `worktree.created`
from its built-in UI — including the repo **right-click → "New worktree"** menu
and the `prefix+shift+g` dialog. This plugin listens for that event and runs
**gren's full post-create hook config** — inline commands, script hooks, named
hooks with branch filters, and user-level hooks — **in the new worktree's own
pane** via `gren hook-run --interactive`. That's a real TTY, so interactive setup
(1Password `op` biometric unlock, `make seed`) and live, uncapped output work,
with the worktree's own direnv-loaded shell; hooks are approved once per project
(then remembered), and per-worktree template values like
`{{ branch | hash_port }}` resolve. It also reports the worktree's deterministic
dev **port** — on the pane, and on herdr ≥ 0.7.4 on the workspace too, so it
outlives setup — though herdr ≥ 0.7.4 only *displays* it once you name `$port`
in your sidebar rows (see
[Showing the port in the sidebar](#showing-the-port-in-the-sidebar)). When
there's no pane, it falls back to `gren hook-run` inline (captured output).
Either way your env files, deps, and hooks are set up automatically — no extra
step. Requires **gren ≥ 0.16.0** (0.15.0 for `--interactive`; 0.16.0 fixes
`$REPO_ROOT` resolving to the main checkout for hooks run from a worktree).

**2. A gren-driven switch/create picker** (`gren.open`): an fzf picker over your
worktrees. Press `Enter` on a match to switch to it, or type a new name and press
`Enter` to create it — you then pick a **base branch** (defaulting to
main/master, else the current branch, like gren's TUI). Typing `pr:42` or `mr:7`
checks out that PR/MR branch. The worktree is created at gren's configured
`worktree_dir`, and its post-create setup runs in a pane with a real TTY (see #1).

**3. A remove picker** (`gren.remove`): an fzf picker over removable worktrees
(everything except the main checkout). Pick one; gren prompts for confirmation
and runs its pre-remove hooks, then the associated herdr workspace is closed.

> **Note on the right-click menu:** herdr's right-click "New worktree" item is
> hardwired to herdr's own create flow, so this plugin can't *replace* it — but
> thanks to the `worktree.created` event it **augments** it: herdr creates the
> checkout, gren sets it up. To make gren *own* the create UI (its path
> convention, base-branch/PR pickers), map a key to `gren.open` (below).

## Requirements

- [**herdr**](https://herdr.dev) ≥ 0.7.0
- [**gren**](https://github.com/langtind/gren) ≥ 0.11.0 — the `gren` CLI on your
  `PATH`. `gren init` is **optional**: since 0.11.0 gren works on any git repo
  with defaults (worktrees under `../<repo>-worktrees`, no hooks), so the picker
  creates worktrees anywhere. Run `gren init` only to add post-create setup
  (env-symlinks, dependency install, hooks) — which the `worktree.created`
  event then runs automatically.
- **fzf** — the interactive picker
- **jq** — JSON parsing
- **bash** — the scripts run with `/bin/bash`

Platforms: macOS and Linux.

## Installation

From the herdr CLI:

```bash
herdr plugin install langtind/gren-herdr
```

Or, for local development, clone and link:

```bash
git clone https://github.com/langtind/gren-herdr
herdr plugin link /path/to/gren-herdr
```

## Usage

```bash
# Switch / create a worktree with gren:
herdr plugin action invoke open --plugin gren

# Remove a worktree with gren:
herdr plugin action invoke remove --plugin gren
```

The `worktree.created` setup hook needs no invocation — it runs automatically
whenever herdr creates a worktree.

## Keybindings

Add `[[keys.command]]` entries to `~/.config/herdr/config.toml` with
`type = "plugin_action"`. The `command` is the plugin action id qualified with
the plugin id (`gren.<action>`; run `herdr plugin action list` to see the ids):

```toml
# Override herdr's built-in "new worktree" (prefix+shift+g) with gren's
# switch/create picker — a custom keybinding wins over the built-in on the same key:
[[keys.command]]
key = "prefix+shift+g"
type = "plugin_action"
command = "gren.open"
description = "Worktree: switch / create (gren)"

[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "gren.remove"
description = "Worktree: remove (gren)"
```

Reload the config after editing it:

```bash
herdr server reload-config
```

## Agent skill: chat-driven create / remove

The pickers cover the human at the keyboard; `skills/issue-worktrees/` covers the
agent in the chat. It's an [agent skill](https://agentskills.io) that lets you say
*"we're fixing ABC-123, create a worktree"* to a coding agent (Claude Code et al.)
and get the full flow: branch name derived from the issue (Linear's
`gitBranchName` via MCP, or `feat|fix/<n>-slug` from a GitHub issue),
`gren create` from the main checkout, and the worktree registered in herdr's
sidebar under the branch name. *"Clean up, remove the worktree"* routes through the
same remover pane as `prefix+shift+d`, so gren's confirmation and pre-remove
hooks keep gating the destructive step — with a guarded non-interactive fallback
for sessions outside herdr.

Install it by linking (or copying) the skill folder into your agent's skills
directory — for Claude Code:

```bash
# from a clone (symlink tracks updates):
ln -s "$PWD/skills/issue-worktrees" ~/.claude/skills/issue-worktrees
```

A `herdr plugin install` puts the plugin under a version-hashed directory
(`~/.config/herdr/plugins/github/…`) that changes on update — copy the folder
from there instead of symlinking, and re-copy after plugin updates.

The skill assumes the `gren` CLI (and, inside herdr, this plugin) is installed;
Linear-issue naming needs a Linear MCP connection in the agent session.

## Removing worktrees

Delete gren worktrees with **`prefix+shift+d`** (the `gren.remove` action), **not
herdr's sidebar**. `gren.remove` runs `gren delete`, which fires gren's
`pre-remove` and `post-remove` hooks while the worktree still exists — so
per-worktree teardown (databases, k8s namespaces, allocated ports) runs and the
delete aborts cleanly if the worktree is dirty.

herdr's native sidebar delete removes the worktree directly and does **not** run
gren's removal hooks (the plugin only subscribes to `worktree.created`). On a
project with per-worktree resources that means orphaned databases/namespaces/ports.

## Notes

- **TTY / interactive setup.** gren normally runs post-create hooks with captured
  stdio (no TTY), and herdr's `worktree.created` event is detached — so hooks
  can't give an interactive tool a terminal on their own. To fix that, the setup
  pane runs `gren hook-run --interactive`, which forces every configured hook
  (inline, script, named, user-level) to inherit the pane's real TTY — no need to
  mark hooks `interactive = true` or keep them in `.gren/post-create.sh`. Because
  a human is at the terminal, `--interactive` also prompts for hook approval the
  first time (remembered per project). Requires gren ≥ 0.16.0.
- **Per-worktree ports / DBs.** Use `{{ branch | hash_port }}` (a deterministic
  port in 10000–19999) and `{{ branch | sanitize_db }}` in your hooks to give each
  worktree its own dev server port and database, so parallel worktrees don't
  collide. The setup pane reports the resolved port on the pane and the workspace
  ([showing it](#showing-the-port-in-the-sidebar) needs a sidebar row on herdr
  ≥ 0.7.4). Note: `hash_port` can *rarely* collide (two branches → same port); if
  that bites, derive the port with `gren step eval` and probe for the next free one.
- **Branch on auto-setup.** herdr's `worktree.created` event carries the new
  checkout path but not the branch name, so the setup hook recovers the branch
  from git (`git symbolic-ref --short HEAD`). Your post-create hook receives it
  as `$2`.

- **Removing a dirty worktree.** `gren delete` refuses a worktree with uncommitted
  or untracked files (commit, stash, or delete them first). The remover surfaces
  gren's message rather than force-deleting.
- **Multiple `worktree.created` plugins.** herdr runs every plugin subscribed to
  the event. If you also run another worktree-bootstrap plugin, both fire on each
  create — disable one to avoid running setup twice.

## Showing the port in the sidebar

Each worktree gets a deterministic dev port (`{{ branch | hash_port }}`). The
setup pane reports it in two places: on **its own pane** (visible immediately,
but gone once setup closes) and — on **herdr ≥ 0.7.4** — as a `port` metadata
token on the worktree's **workspace**, which lasts as long as the worktree does.

On herdr ≥ 0.7.4 **neither is displayed until you ask for it.** A metadata
reporter supplies values only; it cannot choose rows or styling, and *unreported
tokens simply disappear*. herdr's default Space rows are `["state_icon",
"workspace"]` / `["branch", "git_status"]`, which name no custom token — so the
plugin cannot surface this on its own. Name `$port` in your own layout in
`~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  ["branch", "$port"],
]
```

Nothing breaks without it — the port is simply reported and unused.

> **Version note.** herdr 0.7.4 renamed the pane flag: `--custom-status`
> (≤ 0.7.3, which *did* display automatically) became `--token NAME=VALUE`. The
> plugin tries `--token` and falls back, so both generations get a badge, and
> `min_herdr_version` stays at `0.7.0`. On < 0.7.4 the workspace report is
> skipped entirely. `tests/contract_test.sh` asserts at least one badge flag
> still parses — it is what caught this rename.

## Development

The plugin is a manifest plus small bash scripts:

- `herdr-plugin.toml` — event, actions, and panes
- `on-created.sh` — the `worktree.created` setup hook (`gren hook-run`)
- `picker.sh` — the switch / create picker
- `remove.sh` — the remove picker + workspace cleanup
- `helpers.sh` — shared shell helpers (pr:/mr: detection)
- `skills/issue-worktrees/SKILL.md` — the agent skill (chat-driven create/remove)
- `tests/helpers_test.sh` — helper function checks (stubbed gren/herdr)
- `tests/picker_test.sh` — end-to-end picker run against stubbed gren/fzf/herdr
- `tests/bootstrap_test.sh` — setup-pane argument plumbing, incl. the port badge
  and workspace token (stubbed gren/herdr)
- `tests/contract_test.sh` — runs the **real** gren/herdr and asserts the plugin's
  assumptions about their JSON and flags still hold; skips cleanly when a binary
  is absent
- `tests/run.sh` — runs every suite

See [`docs/debugging.md`](docs/debugging.md) for a field guide to diagnosing
gren ↔ herdr issues: the two creation paths, the event model, how to test a gren
build locally without a release, reproducing TTY-only bugs, and a
failure-signature table.

Run the tests:

```bash
bash tests/run.sh          # every suite
bash tests/contract_test.sh  # just the real-binary contract checks
```

The stubbed suites verify the plugin's own control flow; `contract_test.sh` runs
the installed gren/herdr and fails loudly if an upstream assumption (JSON shape,
flag names) has drifted — the class of break that has actually bitten this plugin
before. It runs in [CI](.github/workflows/ci.yml) on every push and PR.

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink gren && herdr plugin link "$PWD"
```

Edits to the bash scripts are picked up on the next run — no relink needed.

## License

[MIT](LICENSE.md) © Arild Langtind
