# tmux-shim — Claude Code split-pane teammates on kitty

Claude Code's split-pane teammate mode (`--teammate-mode tmux`) drives panes by
shelling out to a small subset of `tmux` commands. kitty has no tmux, so this
bridges the gap:

- **`tmux`** — a tiny "fake tmux" (Python 3, stdlib only) that translates the
  tmux commands Claude Code issues (`split-window`, `send-keys`, `capture-pane`,
  `new-session`, `respawn-pane`, …) into kitty remote-control (`kitten @`) calls.
  Unknown commands are logged, never fatal.
- **`claude-kitty`** — a launcher that puts the shim first on `PATH` for that one
  process and starts `claude --teammate-mode tmux`.

The result: Claude Code teammates open as real kitty splits in the lead's tab.

## Requirements — in `kitty.conf`

```conf
allow_remote_control yes
listen_on unix:/tmp/mykitty-{kitty_pid}
enabled_layouts splits,stack      # 'splits' must be the active layout
```

## Install

From the repo root: `./install.sh tmux-shim` — or run this module's installer
directly: `./tmux-shim/install.sh`. Both copy the shim + launcher and add the
kitty.conf settings above (idempotently, with a backup). Manual equivalent:

```bash
mkdir -p ~/.claude/kitty-tmux-shim/bin
cp tmux ~/.claude/kitty-tmux-shim/bin/tmux && chmod +x ~/.claude/kitty-tmux-shim/bin/tmux
cp claude-kitty ~/bin/claude-kitty         && chmod +x ~/bin/claude-kitty   # ~/bin = any dir on PATH
```

## Use

Run `claude-kitty` (with any `claude` args) instead of `claude`.

Every translated call is logged to `~/.claude/kitty-tmux-shim/shim.log`; grep for
`UNHANDLED` to find anything not yet covered. See [../CLAUDE.md](../CLAUDE.md) for
the architecture and how to extend command coverage.

### Optional: teammate-pane spacing

By default the shim leaves pane spacing to your kitty.conf. To give teammate
panes a margin/padding, set `KITTY_TMUX_SHIM_PANE_SPACING` (kitty `set-spacing`
tokens), e.g. `KITTY_TMUX_SHIM_PANE_SPACING="margin=8 padding=6"`. It applies
only to the teammate panes the shim creates, never your other windows.

> **Note:** the launcher intentionally does **not** fake `$TMUX`. If it did,
> Claude Code would wrap its terminal escapes — desktop notifications (OSC
> 99/9/777), clipboard (OSC 52), truecolor — in tmux DCS passthrough, which kitty
> cannot parse, so notifications would silently vanish. See CLAUDE.md.

## Stress test

`stress/` is a self-contained load/regression harness for the shim (no real kitty
needed — it uses a fake `kitten` and a sandbox `$HOME`). See
[stress/README.md](stress/README.md).
