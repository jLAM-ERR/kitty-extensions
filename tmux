#!/usr/bin/env python3
"""
Fake `tmux` for Claude Code split-pane teammate mode on kitty.

Translates the subset of tmux commands that Claude Code's split-pane mode
shells out to, into kitty remote-control (`kitten @`) calls.

Design:
  * Put this file at  ~/.claude/kitty-tmux-shim/bin/tmux  (chmod +x).
  * Prepend ONLY that bin dir to PATH inside the launcher (claude-kitty),
    so you don't shadow real tmux for the rest of your shell.
  * EVERYTHING is logged to ~/.claude/kitty-tmux-shim/shim.log
    -> grep for "UNHANDLED" / "EXC" to discover what to add next.

Requirements:
  * kitty.conf:  allow_remote_control yes
                 listen_on unix:/tmp/kitty
                 enabled_layouts splits,stack   (splits must be active layout)
  * The lead Claude Code session runs inside a kitty window.

This never exits non-zero on an unknown command (that would crash CC); it
logs and returns 0 instead. Check the log to extend coverage.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

try:
    import fcntl
    HAVE_FCNTL = True
except ImportError:  # non-unix; shouldn't happen on macOS
    HAVE_FCNTL = False

HOME = os.path.expanduser("~")
SHIM_DIR = os.path.join(HOME, ".claude", "kitty-tmux-shim")
os.makedirs(SHIM_DIR, exist_ok=True)
LOG = os.path.join(SHIM_DIR, "shim.log")
STATE = os.path.join(SHIM_DIR, "state.json")

FAKE_VERSION = "tmux 3.5a"


# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #
def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} pid={os.getpid()} {msg}\n")
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# locate kitty / kitten
# --------------------------------------------------------------------------- #
def kitty_bin():
    if os.environ.get("KITTY_TMUX_SHIM_BIN"):
        return os.environ["KITTY_TMUX_SHIM_BIN"]
    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    for name in ("kitten", "kitty"):
        for d in path_dirs:
            cand = os.path.join(d, name)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
    for cand in ("/Applications/kitty.app/Contents/MacOS/kitten",
                 "/Applications/kitty.app/Contents/MacOS/kitty"):
        if os.path.isfile(cand):
            return cand
    return "kitten"


KITTY = kitty_bin()


def kitty_rc(args, capture=False, input_text=None):
    cmd = [KITTY, "@"]
    listen = os.environ.get("KITTY_LISTEN_ON")
    if listen:
        cmd += ["--to", listen]
    cmd += args
    log("KITTY " + " ".join(shlex.quote(a) for a in cmd))
    try:
        if capture:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               input=input_text)
        else:
            r = subprocess.run(cmd, text=True, input=input_text,
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
        if r.returncode != 0:
            log(f"  kitty rc={r.returncode} err={(r.stderr or '').strip()}")
        return r.stdout if capture else ""
    except Exception as e:
        log(f"  kitty EXC {e}")
        return ""


# --------------------------------------------------------------------------- #
# state: remember last-created window id for fallback targets
# --------------------------------------------------------------------------- #
def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {"last": None, "ids": []}


def mutate_state(fn):
    f = open(STATE, "a+")
    try:
        if HAVE_FCNTL:
            fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        try:
            st = json.load(f)
        except Exception:
            st = {"last": None, "ids": []}
        fn(st)
        f.seek(0)
        f.truncate()
        json.dump(st, f)
    finally:
        if HAVE_FCNTL:
            fcntl.flock(f, fcntl.LOCK_UN)
        f.close()


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def resolve_id(token):
    """tmux -t token  ->  kitty window id (string of digits)."""
    if not token:
        return load_state().get("last")
    m = re.search(r"%(\d+)", token)          # %5
    if m:
        return m.group(1)
    m = re.search(r"(\d+)\s*$", token)        # sess:1.2  -> 2
    if m:
        return m.group(1)
    return load_state().get("last")           # {last}, {right}, ...


KEY_MAP = {
    "Enter": "enter", "C-m": "enter", "KPEnter": "enter",
    "Escape": "escape", "Esc": "escape",
    "Tab": "tab", "BTab": "shift+tab", "S-Tab": "shift+tab",
    "Space": "space", "BSpace": "backspace", "DC": "delete",
    "Up": "up", "Down": "down", "Left": "left", "Right": "right",
    "Home": "home", "End": "end",
    "PageUp": "page_up", "PageDown": "page_down",
    "PgUp": "page_up", "PgDn": "page_down",
}


def map_key(tok):
    if tok in KEY_MAP:
        return KEY_MAP[tok]
    m = re.fullmatch(r"C-([a-zA-Z])", tok)
    if m:
        return "ctrl+" + m.group(1).lower()
    m = re.fullmatch(r"M-([a-zA-Z])", tok)
    if m:
        return "alt+" + m.group(1).lower()
    m = re.fullmatch(r"S-([a-zA-Z])", tok)
    if m:
        return "shift+" + m.group(1).lower()
    m = re.fullmatch(r"F(\d+)", tok)
    if m:
        return "f" + m.group(1)
    return None  # -> treat as literal text


def split_global(argv):
    """Skip leading global tmux options, return (subcommand, rest)."""
    takes_arg = {"-f", "-L", "-S", "-c", "-T"}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if a.startswith("-"):
            i += 2 if a in takes_arg else 1
            continue
        break
    if i >= len(argv):
        return None, []
    return argv[i], argv[i + 1:]


# --------------------------------------------------------------------------- #
# command handlers
# --------------------------------------------------------------------------- #
def cmd_split_window(args):
    horizontal = False  # tmux -h => left/right => kitty vsplit
    cwd = None
    fmt = None
    cmd_tokens = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-h":
            horizontal = True; i += 1
        elif a == "-v":
            horizontal = False; i += 1
        elif a == "-F":
            fmt = args[i + 1]; i += 2
        elif a == "-c":
            cwd = args[i + 1]; i += 2
        elif a in ("-t", "-l", "-p"):
            i += 2  # target / size: ignore value
        elif a in ("-d", "-P", "-b", "-f", "-I", "-Z"):
            i += 1
        elif a.startswith("-"):
            i += 1
        else:
            cmd_tokens = args[i:]
            break
    location = "vsplit" if horizontal else "hsplit"
    launch = ["launch", "--location", location,
              "--cwd", cwd or "current", "--keep-focus"]
    if cmd_tokens:
        launch += ["--"] + cmd_tokens
    out = kitty_rc(launch, capture=True).strip()
    wid = out.splitlines()[-1].strip() if out else ""
    if not wid.isdigit():
        log(f"  split-window: unexpected launch output {out!r}")
        wid = ""
    else:
        mutate_state(lambda st: (st.update(last=wid), st["ids"].append(wid)))
    pane = "%" + wid if wid else "%0"
    if fmt:
        print(fmt.replace("#{pane_id}", pane).replace("#{pane_index}", wid or "0"))
    else:
        print(pane)


def cmd_send_keys(args):
    target = None
    literal = False
    toks = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-t":
            target = args[i + 1]; i += 2
        elif a == "-l":
            literal = True; i += 1
        elif a == "-N":
            i += 2
        elif a in ("-R", "-H", "-M", "-K"):
            i += 1
        elif a == "--":
            toks.extend(args[i + 1:]); break
        elif a.startswith("-") and a != "-":
            i += 1
        else:
            toks.append(a); i += 1
    wid = resolve_id(target)
    if not wid:
        log("  send-keys: could not resolve target id")
        return
    match = ["--match", "id:" + wid]
    if literal:
        kitty_rc(["send-text"] + match, input_text="".join(toks))
        return
    for tok in toks:
        kname = map_key(tok)
        if kname:
            kitty_rc(["send-key"] + match + [kname])
        else:
            kitty_rc(["send-text"] + match, input_text=tok)


def cmd_capture_pane(args):
    target = None
    scrollback = False
    ansi = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-t":
            target = args[i + 1]; i += 2
        elif a == "-S":
            scrollback = True; i += 2
        elif a in ("-E", "-b"):
            i += 2
        elif a == "-e":
            ansi = True; i += 1
        elif a in ("-p", "-J", "-N", "-T", "-q", "-C", "-a", "-P"):
            i += 1
        elif a.startswith("-"):
            i += 1
        else:
            i += 1
    wid = resolve_id(target)
    if not wid:
        log("  capture-pane: could not resolve target id")
        return
    rc = ["get-text", "--match", "id:" + wid,
          "--extent", "all" if scrollback else "screen"]
    if ansi:
        rc.append("--ansi")
    sys.stdout.write(kitty_rc(rc, capture=True))


def cmd_kill_pane(args):
    target = None
    i = 0
    while i < len(args):
        if args[i] == "-t":
            target = args[i + 1]; i += 2
        else:
            i += 1
    wid = resolve_id(target)
    if wid:
        kitty_rc(["close-window", "--match", "id:" + wid])
        mutate_state(lambda st: st["ids"].remove(wid) if wid in st["ids"] else None)


def cmd_kill_session(args):
    for wid in load_state().get("ids", []):
        kitty_rc(["close-window", "--match", "id:" + wid])
    mutate_state(lambda st: st.update(last=None, ids=[]))


def cmd_select(args):
    target = None
    i = 0
    while i < len(args):
        if args[i] == "-t":
            target = args[i + 1]; i += 2
        else:
            i += 1
    wid = resolve_id(target)
    if wid:
        kitty_rc(["focus-window", "--match", "id:" + wid])


def cmd_display_message(args):
    pflag = False
    fmt = None
    target = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-p":
            pflag = True; i += 1
        elif a == "-t":
            target = args[i + 1]; i += 2
        elif a.startswith("-"):
            i += 1
        else:
            fmt = a; i += 1
    wid = resolve_id(target) or load_state().get("last") or "0"
    if fmt and pflag:
        s = fmt.replace("#{pane_id}", "%" + str(wid)) \
               .replace("#{pane_index}", str(wid))
        s = re.sub(r"#\{[^}]*\}", "", s)  # blank out anything we don't model
        print(s)


HANDLERS = {
    "split-window": cmd_split_window, "splitw": cmd_split_window,
    "send-keys": cmd_send_keys, "send": cmd_send_keys,
    "capture-pane": cmd_capture_pane, "capturep": cmd_capture_pane,
    "kill-pane": cmd_kill_pane, "killp": cmd_kill_pane,
    "kill-window": cmd_kill_pane,
    "kill-session": cmd_kill_session,
    "select-pane": cmd_select, "selectp": cmd_select,
    "select-window": cmd_select, "selectw": cmd_select,
    "display-message": cmd_display_message, "display": cmd_display_message,
}

# Commands we accept silently so CC's flow doesn't break. has-session MUST
# return 0 so CC believes a session already exists.
NOOP = {
    "new-session", "new", "has-session", "start-server", "kill-server",
    "set-option", "set", "set-window-option", "setw", "set-hook",
    "set-environment", "setenv", "show-environment", "showenv",
    "rename-window", "rename-session", "select-layout", "next-layout",
    "resize-pane", "resizep", "refresh-client", "attach-session", "attach",
    "switch-client", "wait-for", "pipe-pane", "list-clients", "lsc",
    "list-panes", "lsp", "list-windows", "lsw", "list-sessions", "ls",
    "server-info", "info", "clock-mode", "rotate-window", "swap-pane",
    "break-pane", "join-pane", "respawn-pane", "command-prompt",
}


def main():
    argv = sys.argv[1:]
    log("ARGV " + " ".join(shlex.quote(a) for a in argv))
    if "-V" in argv:
        print(FAKE_VERSION)
        return 0
    sub, rest = split_global(argv)
    if sub is None:
        return 0
    if sub in HANDLERS:
        try:
            HANDLERS[sub](rest)
        except Exception as e:
            log(f"  HANDLER EXC {sub}: {e!r}")
        return 0
    if sub in NOOP:
        log(f"  NOOP {sub}")
        return 0
    log(f"  UNHANDLED {sub} args={rest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
