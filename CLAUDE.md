# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This repo (`kitty-extensions`) bundles **two independent kitty extensions**, each self-contained under its own directory and separately installable. There is no build system and no dependencies beyond Python 3 and kitty.

**1. `tmux-shim/` — Claude Code split-pane teammates.** Makes Claude Code's **split-pane teammate mode** (`--teammate-mode tmux`) work inside the **kitty** terminal, which has no tmux. Claude Code shells out to a small subset of `tmux` commands to drive panes; the shim intercepts those calls and translates them into kitty remote-control (`kitten @`) commands.

- `tmux-shim/claude-kitty` — bash launcher. Prepends the shim's `bin/` to `PATH`, enables agent teams, then `exec claude --teammate-mode tmux`. It deliberately does **not** fake `$TMUX` (see "Notifications, clipboard & color" below).
- `tmux-shim/tmux` — the fake tmux (Python 3). Parses the tmux argv it receives and emits the equivalent `kitten @` calls.
- `tmux-shim/stress/` — a self-contained load/regression harness for the shim (see its README).

**2. `session-restore/` — reopen previous tabs/splits on launch.** A snapshot script + macOS LaunchAgent. Unrelated to the shim (it only reuses `allow_remote_control`); see `session-restore/README.md`. Those files install elsewhere (`~/.config/kitty/`, `~/Library/LaunchAgents/`) — `save-session.py` via a symlink back to this repo, the LaunchAgent plist as a real copy (launchd can be picky about symlinked plists, and it embeds an absolute path to the script anyway).

Each module has its own idempotent `install.sh` (managing only its own kitty.conf block); the top-level `install.sh` is a chooser that runs one or both (`./install.sh [tmux-shim|session-restore|all]`).

## The repo is the live install (via symlinks)

On this machine the installed paths are **symlinks back to this repo**, so editing a file here is immediately live — there is no copy step and the installed copy can never drift from the repo. Two nuances about when an edit takes effect:

- The **`tmux` shim** is re-executed on every call CC makes, so shim edits apply to the next pane operation without relaunching.
- **`claude-kitty`** is read once at launch, so launcher edits apply to the next `./tmux-shim/claude-kitty` you start (a running session keeps the old one).

The symlinks (installed path → repo file):

- **Shim** (`tmux-shim/tmux`) → `~/.claude/kitty-tmux-shim/bin/tmux` (the launcher prepends that `bin/` to `PATH`)
- **Launcher** (`tmux-shim/claude-kitty`) → `~/bin/claude-kitty` (on `PATH`)
- **Snapshot** (`session-restore/save-session.py`) → `~/.config/kitty/save-session.py`

Recreate a link if one is ever missing (run from the repo root; absolute target, `-n` so an existing link isn't dereferenced):

```bash
ln -sfn "$PWD/tmux-shim/tmux"                   ~/.claude/kitty-tmux-shim/bin/tmux
ln -sfn "$PWD/tmux-shim/claude-kitty"           ~/bin/claude-kitty
ln -sfn "$PWD/session-restore/save-session.py"  ~/.config/kitty/save-session.py
```

The repo scripts must stay executable (`chmod +x tmux-shim/tmux tmux-shim/claude-kitty`) — a symlink inherits its target's mode, so a non-executable target makes the shim/launcher unrunnable. **The `install.sh` scripts (public one-shot installers) deliberately still *copy*** rather than link, so end-users who delete their clone keep a working install; symlinks are a maintainer-only convenience for live editing.

## Running and debugging

```bash
./tmux-shim/claude-kitty [any claude args...] # launch CC with the shim active for this process only
tail -f ~/.claude/kitty-tmux-shim/shim.log    # watch every tmux invocation CC makes
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

Therefore the launcher must **not** fake `$TMUX`. The previous version exported a fake `$TMUX`/`$TMUX_PANE`; that was the cause of missing notifications and is now gated behind `KITTY_TMUX_SHIM_FAKE_TMUX=1` (off by default). Unsetting `$TMUX` lets kitty receive notifications, clipboard, and truecolor natively. If you ever reintroduce a `$TMUX` export "to make detection work", you will silently break notifications again.

**But `$TMUX` is not free — it also picks which pane backend CC uses (see next section).** Even with `--teammate-mode tmux`, Claude Code's `BackendRegistry` branches on `insideTmux = !!process.env.TMUX`:

- `$TMUX` **set** → "running inside tmux session" backend → it splits the **current** pane with `split-window`. This is the mode the shim originally supported (and all it needed).
- `$TMUX` **unset** → "external session mode" → it creates a *detached* `new-session` and reads back `#{pane_id}` before splitting.

So unsetting `$TMUX` (for notifications) forces external-session mode. The shim now emulates that mode too (see below), so you get panes **and** notifications. The `KITTY_TMUX_SHIM_FAKE_TMUX=1` escape hatch remains only as a fallback if a future CC breaks the external path — but turning it on re-breaks notifications.

## External-session ("swarm") mode

When `$TMUX` is unset, CC's `TmuxBackend` drives a detached tmux session it never renders in-terminal (real tmux would need an `attach`). The shim sidesteps that model: it materializes every session/window/pane command as a **real kitty split in the lead session's tab**, so the "detached" panes are simply visible kitty panes — no attach needed. The sequence CC runs (verified by reverse-engineering the CC binary; log tags `[BackendRegistry] Selected: …`, `[TmuxBackend] …`):

1. `display-message -p '#{pane_id}'` (no target) — anchor on the current pane. The shim returns `%$KITTY_WINDOW_ID`; if this is empty CC aborts with "Failed to get current pane ID".
2. `has-session -t <swarm>` — must answer honestly (0 exists / 1 not) so CC decides to create it.
3. `new-session -d -s <swarm> … -P -F '#{pane_id}' -- cat` — the shim opens a kitty pane (teammate #1) and prints its `%id`. Empty output here = "Failed to create swarm session" and no panes. **CC passes a `cat` placeholder command; `pane_command` swaps it for a minimal `/bin/sh`**, because the pane is later driven via `respawn-pane` and kitty can't exec into a running `cat` (and if `cat` exited the window would close).
4. `split-window -t <swarm> … -P -F '#{pane_id}' -- cat` — one kitty pane per further teammate (placeholder also swapped to `/bin/sh`).
5. `select-pane -t %id -T <name>` — the shim focuses the pane and sets its kitty window title to the teammate name.
6. `respawn-pane -k -t %id -- '<real teammate command>'` — this is how CC swaps the actual teammate `claude` process into the placeholder pane. kitty can't exec into a running window, so the shim **`send-text`s the command + `\r` into the pane's shell** (via the `send_text()` helper). Two subtleties, both of which silently produce an **empty pane** if wrong:
   - **`send-text` MUST pass `--stdin`.** `kitten @ send-text --match id:X` *without* `--stdin` exits 0 but sends nothing — it never reads the piped text. This one flag is the whole difference between a live teammate and a blank prompt. All `send_text()` goes through the helper so the flag can't be forgotten.
   - The pane runs **`/bin/sh`, not the user's interactive shell.** A full zsh/bash (prompt framework + plugins) can take seconds to init and its readline/zle startup does a `TCSAFLUSH` that discards type-ahead, dropping the command. `/bin/sh` is minimal, but under load even it can lag, so `wait_for_prompt()` polls the pane until its prompt is drawn before sending.
7. `list-panes` / `list-windows` / `select-layout` / `resize-pane` — pane counting & rebalancing (enumerated from `state.json`; layout/resize are NOOPs — kitty owns tiling).

**Pane placement & focus.** `kitty_launch_split` pins every split to the lead session's tab with `--match window_id:$KITTY_WINDOW_ID`. Without it, `launch` splits whatever kitty window is *currently active*, so teammates land in whichever tab the user is looking at rather than the lead's tab. Two things keep the spawn from stealing focus while agents appear in the background: `launch --keep-focus` (the new pane doesn't grab focus) **and** `cmd_select` not calling `focus-window` — CC issues `select-pane -t %id -T <name>` per teammate, and focusing those panes would yank kitty to the lead's tab (and raise the OS window). The shim only sets the title from `-T`.

**Pane spacing.** `apply_pane_spacing()` can give each teammate pane a margin/padding via `kitten @ set-spacing` (scoped by `--match id:`, so the lead and other windows are never touched). It's **off by default** (`DEFAULT_PANE_SPACING = "none"`) to respect whatever the user set in kitty.conf — `set-spacing` writes absolute values and would otherwise override their configured margin on these panes. Opt in with `KITTY_TMUX_SHIM_PANE_SPACING` (e.g. `"margin=8 padding=6"`, `"margin-h=10"`); the override is per-window and not persisted (`--configured` is not passed).

## How the shim is structured

`tmux`'s `main()` dispatches each invocation through three buckets:

- **`HANDLERS`** — tmux subcommands that map to real kitty actions (`split-window`→`launch`, `send-keys`→`send-text`/`send-key`, `capture-pane`→`get-text`, `kill-pane`→`close-window`, `select-pane`→`set-window-title` for `-T` (title only — deliberately does **not** focus, so background spawns don't steal focus), `respawn-pane`→`send-text` (runs the real teammate command in the placeholder pane's shell), `display-message`; plus the external-session set `new-session`/`new-window`/`has-session`/`list-panes`/`list-windows`). To support a new behavior, write a `cmd_*` handler and register it here.
- **`NOOP`** — commands accepted silently (return 0) so CC's flow doesn't break even though there's nothing to do (e.g. `set-option`, `select-layout`, `resize-pane`, `break-pane`/`join-pane`). Note `has-session` is **no longer** a NOOP: external-session mode needs an honest 0/1 answer (a session it created vs not), so it's a handler that returns an exit code.
- Anything else → logged as `UNHANDLED` and returns 0.

### Invariants when editing `tmux`

- **Never exit non-zero *on unknown commands or handler bugs*.** A crash on those crashes Claude Code, so unknown commands and handler exceptions are logged and return 0. A handler *may* return an int to model legitimate tmux semantics that CC expects and handles — currently only `has-session` (1 = no such session). Don't return non-zero for anything CC doesn't explicitly branch on.
- **Target resolution** goes through `resolve_id()`: it extracts a kitty window id from tmux pane tokens (`%5`, `@5`, `sess:1.2`), falling back to the last-created window recorded in `~/.claude/kitty-tmux-shim/state.json`. For session-scoped targets, `session_name()` pulls the session out (`swarm:1.2` → `swarm`) and the `sessions` map resolves its panes. `state.json` is the only persistent state; it tracks `last`, the list of live window `ids` (kill-session cleanup), and `sessions` (swarm name → `{panes, winname}` for external-session mode).
- **Argv parsing is manual and order-sensitive.** Each handler walks `args` consuming flags and their values (`split_global()` first strips tmux's global options). When adding flags, account for whether they take a value.
- Key translation: `cmd_send_keys` maps tmux key names (`Enter`, `C-c`, `M-x`, `F5`, …) via `KEY_MAP`/`map_key()` to kitty key names; anything unmapped is sent as literal text. `tmux -h` (split horizontally = left/right) maps to kitty `vsplit`; `-v` to `hsplit`.

## Extending tmux command coverage

When Claude Code drives a pane in a way the shim doesn't yet support, it shows up as `UNHANDLED <subcommand>` in `shim.log`. Turn that into coverage:

1. **Find the gap.** `grep -E 'UNHANDLED|EXC' ~/.claude/kitty-tmux-shim/shim.log`. Each `UNHANDLED` line shows the exact subcommand and `args=[...]` CC sent. (`EXC` lines mean a handler already exists but threw — fix the handler instead.)
2. **Decide which bucket it belongs in:**
   - **Needs a real pane effect** (split, send input, focus, close, read text) → write a `cmd_*` handler that emits the matching `kitten @` call via `kitty_rc(...)`, then register it in the **`HANDLERS`** dict (add every alias CC might use, e.g. `splitw` for `split-window`).
   - **Needs to return a value** — query commands such as `show -gv <opt>` or `display-message -p '#{...}'` — the handler **must `print(...)` the string CC expects** to stdout, or CC parses an empty/garbage value. Model only the `#{...}` fields you understand and blank out the rest (see `cmd_display_message`).
   - **Safe to ignore** (CC issues it but nothing needs to happen) → add the subcommand to the **`NOOP`** set so it returns 0 quietly. Anything that must return success for CC to proceed belongs in a handler or NOOP, never left to fall through. (`has-session` is the one command that must return an honest 0/1 — see the invariants above.)
3. **Follow the parsing convention.** In a new handler, walk `args` manually consuming each flag and, where applicable, its value — mirror the existing `cmd_*` functions. `split_global()` has already stripped tmux's global options before your handler runs.
4. **Keep the invariants** from the section above: never exit non-zero, log via `log(...)`, resolve pane targets through `resolve_id()`.
5. **Verify.** The installed `tmux` is a symlink to this repo, so your edit is already live — no reinstall. Relaunch `./tmux-shim/claude-kitty` (or just trigger the next pane op), reproduce the action, and confirm the `UNHANDLED` line is gone from the log.

## Conventions

- `tmux` has no third-party imports (stdlib only) so it runs under whatever Python 3 is on `PATH`; keep it that way.
- kitty binary discovery (`kitty_bin()`) checks `KITTY_TMUX_SHIM_BIN`, then `PATH` for `kitten`/`kitty`, then the macOS app bundle — preserve that fallback chain when touching it.
