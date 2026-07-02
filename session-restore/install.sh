#!/usr/bin/env bash
#
# Installer for "kitty session restore" (save-session.py + LaunchAgent).
# The snapshot script + kitty.conf work anywhere; the LaunchAgent that runs it
# every 60s is macOS-only. Idempotent: safe to re-run. Backs up kitty.conf.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this module dir (session-restore/)

KITTY_DIR="${KITTY_DIR:-$HOME/.config/kitty}"
KITTY_CONF="$KITTY_DIR/kitty.conf"
LA_DIR="${LA_DIR:-$HOME/Library/LaunchAgents}"
LABEL="io.github.jlam-err.kitty-save-session"
PYTHON="/usr/bin/python3"                       # Apple's python3 (script is stdlib-only)
MARK="kitty-extensions:session-restore"         # our own idempotent kitty.conf block

say()    { printf '   %s\n' "$*"; }
section(){ printf '\n==> %s\n' "$*"; }

# --------------------------------------------------------------------------- #
section "kitty session restore"
mkdir -p "$KITTY_DIR"
install -m 755 "$REPO/save-session.py" "$KITTY_DIR/save-session.py"
say "snapshot -> $KITTY_DIR/save-session.py"

# --------------------------------------------------------------------------- #
section "kitty.conf (session-restore settings)"
touch "$KITTY_CONF"
cp "$KITTY_CONF" "$KITTY_CONF.kitty-extensions.bak"

tmp="$(mktemp)"
awk -v m="$MARK" '
  $0 ~ ("^# >>> " m) { skip=1; next }
  skip==1 && $0 ~ ("^# <<< " m) { skip=0; next }
  skip!=1 { print }
' "$KITTY_CONF" > "$tmp" && mv "$tmp" "$KITTY_CONF"

MISSING=()
add_if_missing() { grep -qE "$1" "$KITTY_CONF" || MISSING+=("$2"); }
# allow_remote_control is shared with the tmux-shim module; added by whichever
# module installs first, skipped by the other.
add_if_missing '^[[:space:]]*allow_remote_control[[:space:]]+' 'allow_remote_control yes'
add_if_missing '^[[:space:]]*startup_session[[:space:]]+'      'startup_session ~/.config/kitty/last-session.kitty'
add_if_missing '^[[:space:]]*map[[:space:]].*save-session\.py' \
  "map kitty_mod+s launch --type=background $PYTHON ~/.config/kitty/save-session.py"

if [ "${#MISSING[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# >>> $MARK (added by install.sh) >>>"
    printf '%s\n' "${MISSING[@]}"
    echo "# <<< $MARK <<<"
  } >> "$KITTY_CONF"
  say "added ${#MISSING[@]} setting(s); backup at $KITTY_CONF.kitty-extensions.bak"
else
  say "kitty.conf already has the session-restore settings"
fi

# --------------------------------------------------------------------------- #
if [ "$(uname -s)" = "Darwin" ]; then
  section "LaunchAgent (macOS)"
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
  section "LaunchAgent -- skipped"
  say "Your OS is $(uname -s); the LaunchAgent is macOS-only."
  say "save-session.py + kitty.conf are installed; bind your own timer/keymap to run it,"
  say "or remove the startup_session/map lines from kitty.conf if unused."
fi

# --------------------------------------------------------------------------- #
section "Done (session-restore)"
say "Restart kitty (quit fully, then reopen) so kitty.conf + restore take effect."
