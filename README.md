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
`gren hook-run --type post-create` on the new checkout, so your env files, deps,
and hooks are set up automatically. No extra step.

**2. A gren-driven switch/create picker** (`gren.open`): an fzf picker over your
worktrees. Press `Enter` on a match to open it, or type a new name and press
`Enter` to create it with gren. Typing `pr:42` or `mr:7` checks out that
PR/MR branch. gren's post-create hooks run during creation, and the checkout
opens as a native herdr worktree workspace.

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

## Notes

- **Branch on auto-setup.** herdr's `worktree.created` event carries the new
  checkout path but not the branch name, so the setup hook recovers the branch
  from git (`git symbolic-ref --short HEAD`) before calling `gren hook-run`. Your
  post-create hook still receives the branch as `$2`.
- **Removing a dirty worktree.** `gren delete` refuses a worktree with uncommitted
  or untracked files (commit, stash, or delete them first). The remover surfaces
  gren's message rather than force-deleting.
- **Multiple `worktree.created` plugins.** herdr runs every plugin subscribed to
  the event. If you also run another worktree-bootstrap plugin, both fire on each
  create — disable one to avoid running setup twice.

## Development

The plugin is a manifest plus small bash scripts:

- `herdr-plugin.toml` — event, actions, and panes
- `on-created.sh` — the `worktree.created` setup hook (`gren hook-run`)
- `picker.sh` — the switch / create picker
- `remove.sh` — the remove picker + workspace cleanup
- `helpers.sh` — shared shell helpers (pr:/mr: detection)
- `tests/helpers_test.sh` — helper function checks

Run the tests:

```bash
bash tests/helpers_test.sh
```

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink gren && herdr plugin link "$PWD"
```

Edits to the bash scripts are picked up on the next run — no relink needed.

## License

[MIT](LICENSE.md) © Arild Langtind
