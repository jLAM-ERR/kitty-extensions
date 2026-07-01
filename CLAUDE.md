# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A two-file shim that makes Claude Code's **split-pane teammate mode** (`--teammate-mode tmux`) work inside the **kitty** terminal, which has no tmux. Claude Code shells out to a small subset of `tmux` commands to drive panes; this project intercepts those calls and translates them into kitty remote-control (`kitten @`) commands. There is no build system, no test suite, and no dependencies beyond Python 3 and kitty.

- `claude-kitty` — bash launcher. Prepends the shim's `bin/` to `PATH`, enables agent teams, then `exec claude --teammate-mode tmux`. It deliberately does **not** fake `$TMUX` (see "Notifications, clipboard & color" below).
- `tmux` — the fake tmux (Python 3). Parses the tmux argv it receives and emits the equivalent `kitten @` calls.

A separate, self-contained concern lives in **`session-restore/`** — a snapshot script + macOS LaunchAgent that make kitty reopen the previous tabs/splits on launch. It is unrelated to the tmux shim (it only reuses `allow_remote_control`); see `session-restore/README.md`. Like the shim, those files install elsewhere (`~/.config/kitty/`, `~/Library/LaunchAgents/`) — `save-session.py` via a symlink back to this repo, the LaunchAgent plist as a real copy (launchd can be picky about symlinked plists, and it embeds an absolute path to the script anyway).

## The repo is the live install (via symlinks)

On this machine the installed paths are **symlinks back to this repo**, so editing a file here is immediately live — there is no copy step and the installed copy can never drift from the repo. Two nuances about when an edit takes effect:

- The **`tmux` shim** is re-executed on every call CC makes, so shim edits apply to the next pane operation without relaunching.
- **`claude-kitty`** is read once at launch, so launcher edits apply to the next `./claude-kitty` you start (a running session keeps the old one).

The symlinks (installed path → repo file):

- **Shim** (`tmux`) → `~/.claude/kitty-tmux-shim/bin/tmux` (the launcher prepends that `bin/` to `PATH`)
- **Launcher** (`claude-kitty`) → `~/bin/claude-kitty` (on `PATH`)
- **Snapshot** (`session-restore/save-session.py`) → `~/.config/kitty/save-session.py`

Recreate a link if one is ever missing (run from the repo root; absolute target, `-n` so an existing link isn't dereferenced):

```bash
ln -sfn "$PWD/tmux"                            ~/.claude/kitty-tmux-shim/bin/tmux
ln -sfn "$PWD/claude-kitty"                    ~/bin/claude-kitty
ln -sfn "$PWD/session-restore/save-session.py" ~/.config/kitty/save-session.py
```

The repo scripts must stay executable (`chmod +x tmux claude-kitty`) — a symlink inherits its target's mode, so a non-executable target makes the shim/launcher unrunnable. **`install.sh` (the public one-shot installer) deliberately still *copies*** rather than links, so end-users who delete their clone keep a working install; symlinks are a maintainer-only convenience for live editing.

## Running and debugging

```bash
./claude-kitty [any claude args...]          # launch CC with the shim active for this process only
tail -f ~/.claude/kitty-tmux-shim/shim.log   # watch every tmux invocation CC makes
grep -E 'UNHANDLED|EXC' ~/.claude/kitty-tmux-shim/shim.log   # find gaps to fix
```

The shim logs **every** call. The log is the primary development tool: when CC drives a pane in a way that fails, the corresponding `UNHANDLED <subcommand>` or `HANDLER EXC` line tells you exactly what to add.

Required `kitty.conf` for the shim to reach kitty:
```
allow_remote_control yes
listen_on unix:/tmp/kitty
enabled_layouts splits,stack      # 'splits' must be the active layout
```

## Notifications, clipboard & color: why `$TMUX` must stay unset

This is the subtle bit. Claude Code emits some things as raw terminal escape sequences written to its own stdout (the kitty window) rather than as `tmux` subcommands — notably **desktop notifications** (OSC 99 kitty / OSC 9 iTerm / OSC 777 ghostty), **clipboard** writes (OSC 52), truecolor, and capability probes. The shim never sees these — they don't go through the `tmux` binary.

When Claude Code believes it is inside tmux (i.e. `$TMUX` is set), it wraps every one of those escapes in **tmux DCS passthrough** (`\ePtmux;…\e\\`). **kitty does not parse tmux passthrough, so it silently drops them** — no "Claude needs your input" notification ever fires, clipboard copies vanish, and color is downgraded to 256. The `tmux` shim *cannot* fix this, because the escapes never reach it.

Therefore the launcher must **not** fake `$TMUX`. The previous version exported a fake `$TMUX`/`$TMUX_PANE`; that was the cause of missing notifications and is now gated behind `KITTY_TMUX_SHIM_FAKE_TMUX=1` (off by default). Teammate split-pane mode keeps working because it is selected by the `--teammate-mode tmux` flag (Claude Code's `TmuxBackend`), **not** by `$TMUX` — so unsetting `$TMUX` costs nothing and lets kitty receive notifications, clipboard, and truecolor natively. If you ever reintroduce a `$TMUX` export "to make detection work", you will silently break notifications again.

## How the shim is structured

`tmux`'s `main()` dispatches each invocation through three buckets:

- **`HANDLERS`** — tmux subcommands that map to real kitty actions (`split-window`→`launch`, `send-keys`→`send-text`/`send-key`, `capture-pane`→`get-text`, `kill-pane`→`close-window`, `select-pane`→`focus-window`, `display-message`). To support a new behavior, write a `cmd_*` handler and register it here.
- **`NOOP`** — commands accepted silently (return 0) so CC's flow doesn't break even though there's nothing to do (e.g. `new-session`, `set-option`, layout commands). `has-session` lives here and **must** return 0 so CC believes a session already exists.
- Anything else → logged as `UNHANDLED` and returns 0.

### Invariants when editing `tmux`

- **Never exit non-zero.** A non-zero exit crashes Claude Code. Unknown commands and handler exceptions are logged and return 0 instead. Preserve this.
- **Target resolution** goes through `resolve_id()`: it extracts a kitty window id from tmux pane tokens (`%5`, `sess:1.2`), falling back to the last-created window recorded in `~/.claude/kitty-tmux-shim/state.json`. `state.json` is the only persistent state; it tracks `last` and the list of live window `ids` for kill-session cleanup.
- **Argv parsing is manual and order-sensitive.** Each handler walks `args` consuming flags and their values (`split_global()` first strips tmux's global options). When adding flags, account for whether they take a value.
- Key translation: `cmd_send_keys` maps tmux key names (`Enter`, `C-c`, `M-x`, `F5`, …) via `KEY_MAP`/`map_key()` to kitty key names; anything unmapped is sent as literal text. `tmux -h` (split horizontally = left/right) maps to kitty `vsplit`; `-v` to `hsplit`.

## Extending tmux command coverage

When Claude Code drives a pane in a way the shim doesn't yet support, it shows up as `UNHANDLED <subcommand>` in `shim.log`. Turn that into coverage:

1. **Find the gap.** `grep -E 'UNHANDLED|EXC' ~/.claude/kitty-tmux-shim/shim.log`. Each `UNHANDLED` line shows the exact subcommand and `args=[...]` CC sent. (`EXC` lines mean a handler already exists but threw — fix the handler instead.)
2. **Decide which bucket it belongs in:**
   - **Needs a real pane effect** (split, send input, focus, close, read text) → write a `cmd_*` handler that emits the matching `kitten @` call via `kitty_rc(...)`, then register it in the **`HANDLERS`** dict (add every alias CC might use, e.g. `splitw` for `split-window`).
   - **Needs to return a value** — query commands such as `show -gv <opt>` or `display-message -p '#{...}'` — the handler **must `print(...)` the string CC expects** to stdout, or CC parses an empty/garbage value. Model only the `#{...}` fields you understand and blank out the rest (see `cmd_display_message`).
   - **Safe to ignore** (CC issues it but nothing needs to happen) → add the subcommand to the **`NOOP`** set so it returns 0 quietly. Anything that must return success for CC to proceed (like `has-session`) belongs here, never left to fall through.
3. **Follow the parsing convention.** In a new handler, walk `args` manually consuming each flag and, where applicable, its value — mirror the existing `cmd_*` functions. `split_global()` has already stripped tmux's global options before your handler runs.
4. **Keep the invariants** from the section above: never exit non-zero, log via `log(...)`, resolve pane targets through `resolve_id()`.
5. **Verify.** The installed `tmux` is a symlink to this repo, so your edit is already live — no reinstall. Relaunch `./claude-kitty` (or just trigger the next pane op), reproduce the action, and confirm the `UNHANDLED` line is gone from the log.

## Conventions

- `tmux` has no third-party imports (stdlib only) so it runs under whatever Python 3 is on `PATH`; keep it that way.
- kitty binary discovery (`kitty_bin()`) checks `KITTY_TMUX_SHIM_BIN`, then `PATH` for `kitten`/`kitty`, then the macOS app bundle — preserve that fallback chain when touching it.
