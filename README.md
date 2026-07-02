# kitty-extensions

Two small, **independent** extensions for the [kitty](https://sw.kovidgoyal.net/kitty/)
terminal, aimed at running [Claude Code](https://claude.com/claude-code)
comfortably inside kitty. Each lives in its own directory and installs on its own.

| Module | What it does | Platform |
|--------|--------------|----------|
| [`tmux-shim/`](tmux-shim/) | Run Claude Code's split-pane teammate mode in kitty (no tmux) — teammates open as real kitty splits | any OS with kitty + python3 |
| [`session-restore/`](session-restore/) | Reopen the previous tabs / splits (each pane's cwd + program) on launch | macOS (LaunchAgent) |

## Install

```bash
git clone https://github.com/jLAM-ERR/kitty-extensions.git
cd kitty-extensions
./install.sh                 # choose interactively (installs both if non-interactive)
./install.sh tmux-shim       # just the shim + launcher
./install.sh session-restore # just session restore
./install.sh all             # both, non-interactively
```

Each module also has its own installer (`tmux-shim/install.sh`,
`session-restore/install.sh`) if you prefer to run them directly. All installers
are idempotent, back up `kitty.conf` before editing, and manage only their own
settings block within it. Restart kitty afterwards.

## Modules

### [`tmux-shim/`](tmux-shim/) — Claude Code split-pane teammates

Claude Code's teammate mode (`--teammate-mode tmux`) drives panes via a subset of
`tmux` commands; kitty has no tmux, so a tiny "fake tmux" (Python 3, stdlib only)
translates them into kitty remote-control (`kitten @`) calls. Run `claude-kitty`
instead of `claude` and teammates open as real kitty splits. See
[tmux-shim/README.md](tmux-shim/README.md) and [CLAUDE.md](CLAUDE.md).

### [`session-restore/`](session-restore/) — reopen tabs/splits on launch

A snapshot script captures the live layout (`kitten @ ls`) every 60s via a
LaunchAgent; kitty's `startup_session` replays it after a quit, crash, or reboot.
macOS-specific. See [session-restore/README.md](session-restore/README.md).

## License

Released into the public domain under [The Unlicense](LICENSE) — use, modify, and
distribute it however you want, no attribution required.
