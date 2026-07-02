# kitty session restore (macOS)

Make kitty reopen the previous tabs / windows / splits — each pane's working
directory and foreground program — after a quit, crash, or reboot. kitty has no
built-in auto-save; this snapshots the live layout into a session file that
`startup_session` replays on the next launch.

These files are **source copies**, like the rest of this repo. Editing them here
does nothing until you install them to the paths below.

**Easy install:** from the repo root run `./install.sh session-restore` (or this
module's installer directly, `./session-restore/install.sh`) — it copies the
script, adds the kitty.conf lines, and loads the LaunchAgent, idempotently, with
a kitty.conf backup. The manual steps are below if you prefer.

## Pieces

| Repo file | Installed to | Role |
|---|---|---|
| `save-session.py` | `~/.config/kitty/save-session.py` | Reads `kitten @ ls`, writes `~/.config/kitty/last-session.kitty`. Atomic; never overwrites unless kitty is running with ≥1 window. |
| `io.github.jlam-err.kitty-save-session.plist` | `~/Library/LaunchAgents/` | LaunchAgent: runs the snapshot every 60s and at login. |
| (kitty.conf snippet, below) | `~/.config/kitty/kitty.conf` | `startup_session` to restore + a manual checkpoint key. |

## How it works

1. The LaunchAgent runs `save-session.py` every 60s. It locates the running
   kitty via the `/tmp/mykitty-*` control socket (so it works even though
   launchd has no `KITTY_LISTEN_ON`), dumps the layout, and writes
   `~/.config/kitty/last-session.kitty`.
2. On the next launch, `startup_session` replays that file: same OS windows,
   tabs + titles, split layout, per-pane cwd, and re-runs each pane's foreground
   program.

The per-pane cwd is read from the **foreground process**, not kitty's window
cwd, which is unreliable unless the shell emits OSC 7. The program to relaunch
is the lowest-pid foreground process (the one you launched; its helper children
have larger pids); a plain shell restores as a plain shell.

kitty runs session `launch` commands with its own minimal GUI PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`), not your interactive shell's PATH, so the
snapshot makes relaunched programs work anyway:

* **claude teammate sessions** are routed through `~/bin/claude-kitty
  --continue` (by absolute path) instead of bare `claude` — otherwise they come
  back without the tmux shim on PATH or `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`,
  i.e. teammate mode broken (and bare `claude` isn't even on kitty's PATH).
  `--continue` resumes that directory's last conversation rather than starting
  fresh. `claude-kitty` itself prepends `~/.local/bin` so its `exec claude`
  resolves under that minimal PATH.
* **other programs** are resolved to an absolute path against a realistic PATH
  (`~/.local/bin`, `~/bin`, Homebrew, ...) so e.g. `nvim` relaunches correctly.

## Install

Requires `allow_remote_control yes` in kitty.conf (already set for the tmux shim).

```bash
cp save-session.py ~/.config/kitty/save-session.py
chmod +x ~/.config/kitty/save-session.py
cp io.github.jlam-err.kitty-save-session.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/io.github.jlam-err.kitty-save-session.plist
launchctl kickstart  "gui/$(id -u)/io.github.jlam-err.kitty-save-session"   # snapshot once now
```

Add to `~/.config/kitty/kitty.conf`:

```conf
startup_session ~/.config/kitty/last-session.kitty
# Optional: checkpoint the current layout immediately (ctrl+shift+s)
map kitty_mod+s launch --type=background /usr/bin/python3 ~/.config/kitty/save-session.py
```

The LaunchAgent runs Apple's `/usr/bin/python3` (stable absolute path; the script
is stdlib-only). The `kitten` binary defaults to
`/Applications/kitty.app/Contents/MacOS/kitten` — override with
`KITTY_SAVE_KITTEN` if kitty lives elsewhere.

## Caveats

- **~60s granularity** — layout changes in the last minute before a crash can be
  lost. Press `ctrl+shift+s` for an exact checkpoint before quitting.
- **Programs restart fresh** — no scrollback or live process state; a pane
  mid-task re-runs its command. (claude is the exception: it relaunches with
  `--continue`, resuming that directory's last conversation.) To restore certain
  programs (`ssh`, dev servers, even `claude`) as a plain shell in the right cwd
  instead, add their basenames to the `SHELLS` set in `save-session.py`, or drop
  program-relaunch entirely by removing the `-- <cmd>` emission in `render()`.
- **Split sizes are approximate**; focus is best-effort per tab (kitty session
  files can't encode exact split geometry).

## Uninstall

```bash
launchctl bootout "gui/$(id -u)/io.github.jlam-err.kitty-save-session"
# then remove the startup_session / map lines from kitty.conf
```
