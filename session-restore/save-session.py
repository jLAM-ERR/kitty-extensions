#!/usr/bin/env python3
"""
Snapshot the live kitty layout into a session file for `startup_session` restore.

Reads `kitten @ ls` and writes ~/.config/kitty/last-session.kitty so that, with

    startup_session ~/.config/kitty/last-session.kitty

in kitty.conf, the next kitty launch reopens the same OS windows, tabs, tab
titles, split layout, per-pane working directory, and re-runs each pane's
foreground program.

Run it periodically (a LaunchAgent every 60s) and/or bind it to a key. It is
SAFE to run when kitty is down: it never overwrites the session file unless a
running kitty reports at least one window, so a crash/quit can't wipe your
saved layout. The write is atomic (temp file + rename).

Limitations (kitty cannot reconstruct these from a session file):
  * scrollback and live process state are not restored (programs are re-run fresh);
  * exact split sizes are approximated by re-issuing splits in order;
  * focus is restored per-tab on a best-effort basis.
"""
import glob
import json
import os
import shlex
import subprocess
import sys
import tempfile

KITTEN = (os.environ.get("KITTY_SAVE_KITTEN")
          or "/Applications/kitty.app/Contents/MacOS/kitten")
OUT = os.path.expanduser("~/.config/kitty/last-session.kitty")
HOME = os.path.expanduser("~")

# Foreground processes whose basename is one of these are treated as "just a
# shell" -> restored as a plain shell in the right cwd, not re-run as a command.
SHELLS = {"bash", "zsh", "fish", "sh", "tcsh", "csh", "ksh", "dash", "nu", "xonsh"}


def sockets():
    """Reachable kitty control sockets, most specific first.

    When invoked from inside kitty (a key binding), KITTY_LISTEN_ON points at
    this instance. From a LaunchAgent there is no such env, so glob the per-pid
    sockets created by `listen_on unix:/tmp/mykitty-{kitty_pid}`.
    """
    env = os.environ.get("KITTY_LISTEN_ON")
    if env:
        return [env]
    return ["unix:" + p for p in sorted(glob.glob("/tmp/mykitty-*"))]


def ls(sock):
    try:
        r = subprocess.run([KITTEN, "@", "--to", sock, "ls"],
                           capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def is_shell(cmdline):
    if not cmdline:
        return True
    base = os.path.basename(cmdline[0]).lstrip("-")
    return base in SHELLS


def primary_process(win):
    """Return (cmdline_or_None, cwd) for a window's main foreground program.

    kitty's per-window `cwd` is unreliable -- it only tracks `cd` if the shell
    emits OSC 7, which many setups don't -- so read cwd from the process itself.
    The tty's foreground process group never contains both an idle shell and a
    running program, so the lowest-pid foreground process is the one the user
    launched; its children (helpers, MCP servers, caffeinate, ...) have larger
    pids. cmdline of None means "just a shell" -> restore a plain shell.
    """
    procs = win.get("foreground_processes") or []
    if not procs:
        return None, win.get("cwd") or HOME
    primary = min(procs, key=lambda p: p.get("pid") or (1 << 62))
    cwd = primary.get("cwd") or win.get("cwd") or HOME
    cmd = primary.get("cmdline") or []
    if is_shell(cmd):
        return None, cwd
    return cmd, cwd


def render(os_windows):
    out = []
    for oi, osw in enumerate(os_windows):
        if oi > 0:
            out.append("new_os_window")
        for ti, tab in enumerate(osw.get("tabs") or []):
            if ti > 0:
                out.append("new_tab")
            title = (tab.get("title") or "").strip().replace("\n", " ")
            if title:
                out.append("tab_title " + title)
            out.append("layout " + (tab.get("layout") or "splits"))
            wins = tab.get("windows") or []
            focus_after = None
            for wi, w in enumerate(wins):
                cmd, cwd = primary_process(w)
                parts = ["launch", "--cwd", shlex.quote(cwd)]
                if cmd:
                    parts.append("--")
                    parts.extend(shlex.quote(a) for a in cmd)
                out.append(" ".join(parts))
                if w.get("is_focused") or w.get("is_active"):
                    focus_after = len(out)
            # Best-effort: focus the active window of the tab. `focus` applies to
            # the most recently created window, so emit it right after that launch.
            if focus_after is not None:
                out.insert(focus_after, "focus")
    return "\n".join(out) + "\n"


def main():
    for sock in sockets():
        data = ls(sock)
        if not data:
            continue
        # Only the windows belonging to a reachable, non-empty instance.
        if not any(osw.get("tabs") for osw in data):
            continue
        text = render(data)
        d = os.path.dirname(OUT)
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".last-session.")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp, OUT)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return 0
    # kitty not running / unreachable: leave the existing session file intact.
    return 0


if __name__ == "__main__":
    sys.exit(main())
