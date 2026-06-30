# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A two-file shim that makes Claude Code's **split-pane teammate mode** (`--teammate-mode tmux`) work inside the **kitty** terminal, which has no tmux. Claude Code shells out to a small subset of `tmux` commands to drive panes; this project intercepts those calls and translates them into kitty remote-control (`kitten @`) commands. There is no build system, no test suite, and no dependencies beyond Python 3 and kitty.

- `claude-kitty` — bash launcher. Prepends the shim's `bin/` to `PATH`, sets teammate-mode env vars, fakes `$TMUX`/`$TMUX_PANE`, then `exec claude --teammate-mode tmux`.
- `tmux` — the fake tmux (Python 3). Parses the tmux argv it receives and emits the equivalent `kitten @` calls.

## Critical: the repo files are a source copy, not the live shim

The launcher and shim load from `~/.claude/kitty-tmux-shim/`, **not** from this repo:

- `claude-kitty` execs the fake tmux at `~/.claude/kitty-tmux-shim/bin/tmux`.
- This repo's `tmux` is a working copy. It is currently byte-identical to the installed one, but **editing `tmux` here changes nothing until you copy it into place**:
  ```bash
  cp tmux ~/.claude/kitty-tmux-shim/bin/tmux && chmod +x ~/.claude/kitty-tmux-shim/bin/tmux
  ```
  After any change to `tmux`, reinstall and relaunch Claude Code for it to take effect.

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
5. **Reinstall and verify.** `cp tmux ~/.claude/kitty-tmux-shim/bin/tmux && chmod +x ~/.claude/kitty-tmux-shim/bin/tmux`, relaunch `./claude-kitty`, reproduce the action, and confirm the `UNHANDLED` line is gone from the log.

## Conventions

- `tmux` has no third-party imports (stdlib only) so it runs under whatever Python 3 is on `PATH`; keep it that way.
- kitty binary discovery (`kitty_bin()`) checks `KITTY_TMUX_SHIM_BIN`, then `PATH` for `kitten`/`kitty`, then the macOS app bundle — preserve that fallback chain when touching it.
