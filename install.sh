#!/usr/bin/env bash
#
# Installer for kitty-extensions.
#
#   1) Claude Code <- tmux shim   (claude-kitty + tmux)   any OS with kitty + python3
#   2) kitty session restore      (save-session.py + LaunchAgent + kitty.conf)   macOS only
#
# Idempotent: safe to re-run. Backs up kitty.conf before editing it. Override any
# path with an env var, e.g.  BIN_DIR=~/.local/bin ./install.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHIM_DIR="${SHIM_DIR:-$HOME/.claude/kitty-tmux-shim}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"                 # must be on PATH; save-session.py expects ~/bin/claude-kitty
KITTY_DIR="${KITTY_DIR:-$HOME/.config/kitty}"
KITTY_CONF="$KITTY_DIR/kitty.conf"
LA_DIR="$HOME/Library/LaunchAgents"
LABEL="io.github.jlam-err.kitty-save-session"
PYTHON="/usr/bin/python3"                       # Apple's python3 for the LaunchAgent (script is stdlib-only)

say()    { printf '   %s\n' "$*"; }
section(){ printf '\n==> %s\n' "$*"; }

# ----------------------------------------------------------------------------- #
section "Claude Code <- tmux shim"
mkdir -p "$SHIM_DIR/bin"
install -m 755 "$REPO/tmux" "$SHIM_DIR/bin/tmux"
say "shim     -> $SHIM_DIR/bin/tmux"
mkdir -p "$BIN_DIR"
install -m 755 "$REPO/claude-kitty" "$BIN_DIR/claude-kitty"
say "launcher -> $BIN_DIR/claude-kitty"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "WARNING: $BIN_DIR is not on your PATH -- add it so 'claude-kitty' resolves." ;;
esac

# ----------------------------------------------------------------------------- #
section "kitty.conf"
mkdir -p "$KITTY_DIR"
touch "$KITTY_CONF"
cp "$KITTY_CONF" "$KITTY_CONF.kitty-extensions.bak"

# Drop any block we added on a previous run, so this stays idempotent.
tmp="$(mktemp)"
awk '
  /^# >>> kitty-extensions/ { skip=1; next }
  skip==1 && /^# <<< kitty-extensions/ { skip=0; next }
  skip!=1 { print }
' "$KITTY_CONF" > "$tmp" && mv "$tmp" "$KITTY_CONF"

MISSING=()
add_if_missing() {  # <extended-regex to detect existing> <line to add>
  grep -qE "$1" "$KITTY_CONF" || MISSING+=("$2")
}
add_if_missing '^[[:space:]]*allow_remote_control[[:space:]]+' 'allow_remote_control yes'
add_if_missing '^[[:space:]]*listen_on[[:space:]]+'            'listen_on unix:/tmp/mykitty-{kitty_pid}'
add_if_missing '^[[:space:]]*enabled_layouts[[:space:]]+'      'enabled_layouts splits,stack'
add_if_missing '^[[:space:]]*startup_session[[:space:]]+'      'startup_session ~/.config/kitty/last-session.kitty'
add_if_missing '^[[:space:]]*map[[:space:]].*save-session\.py' \
  "map kitty_mod+s launch --type=background $PYTHON ~/.config/kitty/save-session.py"

if [ "${#MISSING[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# >>> kitty-extensions (added by install.sh) >>>"
    printf '%s\n' "${MISSING[@]}"
    echo "# <<< kitty-extensions <<<"
  } >> "$KITTY_CONF"
  say "added ${#MISSING[@]} setting(s); backup at $KITTY_CONF.kitty-extensions.bak"
else
  say "already has the needed settings (backup at $KITTY_CONF.kitty-extensions.bak)"
fi

# ----------------------------------------------------------------------------- #
if [ "$(uname -s)" = "Darwin" ]; then
  section "Session restore (LaunchAgent)"
  install -m 755 "$REPO/session-restore/save-session.py" "$KITTY_DIR/save-session.py"
  say "snapshot -> $KITTY_DIR/save-session.py"

  PLIST="$LA_DIR/$LABEL.plist"
  mkdir -p "$LA_DIR"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$KITTY_DIR/save-session.py</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>/tmp/kitty-save-session.err</string>
    <key>StandardOutPath</key>
    <string>/tmp/kitty-save-session.out</string>
</dict>
</plist>
PLISTEOF
  say "agent    -> $PLIST"

  launchctl bootout   "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart "gui/$(id -u)/$LABEL"
  say "LaunchAgent loaded -- snapshots the layout every 60s"
else
  section "Session restore -- skipped"
  say "Your OS is $(uname -s); the LaunchAgent + startup_session restore are macOS-only."
  say "The tmux shim above works fine; just remove the startup_session/map lines from kitty.conf."
fi

# ----------------------------------------------------------------------------- #
section "Done"
say "Restart kitty (quit fully, then reopen) so kitty.conf and session restore take effect."
say "Run 'claude-kitty' (with any claude args) instead of 'claude' for split-pane teammates."
