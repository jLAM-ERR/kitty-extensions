# kitty-extensions

Small extensions for the [kitty](https://sw.kovidgoyal.net/kitty/) terminal,
aimed at running [Claude Code](https://claude.com/claude-code) comfortably inside
kitty on macOS.

## Quick install

```bash
git clone https://github.com/jLAM-ERR/kitty-extensions.git
cd kitty-extensions
./install.sh
```

`install.sh` is idempotent and installs both components (the shim + launcher on
any OS; session restore on macOS), backing up `kitty.conf` before editing it.
Then restart kitty and run `claude-kitty`. Per-component manual steps are below.

## Contents

### 1. Claude Code split-pane teammates on kitty — `claude-kitty` + `tmux`

Claude Code's split-pane teammate mode (`--teammate-mode tmux`) drives panes by
shelling out to a small subset of `tmux` commands. kitty has no tmux, so this
bridges the gap:

- **`tmux`** — a tiny "fake tmux" (Python 3, stdlib only) that translates the
  tmux commands Claude Code issues (`split-window`, `send-keys`, `capture-pane`,
  …) into kitty remote-control (`kitten @`) calls. Unknown commands are logged,
  never fatal.
- **`claude-kitty`** — a launcher that puts the shim first on `PATH` for that one
  process and starts `claude --teammate-mode tmux`.

The result: Claude Code teammates open as real kitty splits.

**Requirements** — in `kitty.conf`:

```conf
allow_remote_control yes
listen_on unix:/tmp/mykitty-{kitty_pid}
enabled_layouts splits,stack      # 'splits' must be the active layout
```

**Install:**

```bash
mkdir -p ~/.claude/kitty-tmux-shim/bin
cp tmux ~/.claude/kitty-tmux-shim/bin/tmux && chmod +x ~/.claude/kitty-tmux-shim/bin/tmux
cp claude-kitty ~/bin/claude-kitty       && chmod +x ~/bin/claude-kitty   # ~/bin = any dir on PATH
```

**Use:** run `claude-kitty` (with any `claude` args) instead of `claude`.

Every translated call is logged to `~/.claude/kitty-tmux-shim/shim.log`; grep for
`UNHANDLED` to find anything not yet covered. See [CLAUDE.md](CLAUDE.md) for the
architecture and how to extend command coverage.

> **Note:** the launcher intentionally does **not** fake `$TMUX`. If it did,
> Claude Code would wrap its terminal escapes — desktop notifications (OSC
> 99/9/777), clipboard (OSC 52), truecolor — in tmux DCS passthrough, which kitty
> cannot parse, so notifications would silently vanish.

### 2. Session restore — `session-restore/`

Make kitty reopen the previous tabs / windows / splits on launch — each pane's
working directory and foreground program — after a quit, crash, or reboot. A
snapshot script captures the live layout (via `kitten @ ls`) every 60 seconds
through a LaunchAgent, and `startup_session` replays it. macOS-specific.

See [session-restore/README.md](session-restore/README.md) for install and
details.

## License

Released into the public domain under [The Unlicense](LICENSE) — use, modify, and
distribute it however you want, no attribution required.
