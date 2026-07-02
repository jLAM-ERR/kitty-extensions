#!/usr/bin/env bash
#
# Installer for the "Claude Code <- tmux shim" (claude-kitty + tmux).
# Works on any OS with kitty + python3. Idempotent: safe to re-run.
# Backs up kitty.conf before editing. Override paths via env vars, e.g.
#   BIN_DIR=~/.local/bin ./install.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this module dir (tmux-shim/)

SHIM_DIR="${SHIM_DIR:-$HOME/.claude/kitty-tmux-shim}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"                 # must be on PATH for 'claude-kitty'
KITTY_DIR="${KITTY_DIR:-$HOME/.config/kitty}"
KITTY_CONF="$KITTY_DIR/kitty.conf"
MARK="kitty-extensions:tmux-shim"              # our own idempotent kitty.conf block

say()    { printf '   %s\n' "$*"; }
section(){ printf '\n==> %s\n' "$*"; }

# --------------------------------------------------------------------------- #
section "Claude Code <- tmux shim"
mkdir -p "$SHIM_DIR/bin"
chmod 700 "$SHIM_DIR"                              # state.json / shim.log stay private
install -m 755 "$REPO/tmux" "$SHIM_DIR/bin/tmux"
say "shim     -> $SHIM_DIR/bin/tmux"
mkdir -p "$BIN_DIR"
install -m 755 "$REPO/claude-kitty" "$BIN_DIR/claude-kitty"
say "launcher -> $BIN_DIR/claude-kitty"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "WARNING: $BIN_DIR is not on your PATH -- add it so 'claude-kitty' resolves." ;;
esac

# --------------------------------------------------------------------------- #
section "kitty.conf (tmux-shim settings)"
mkdir -p "$KITTY_DIR"
touch "$KITTY_CONF"
cp "$KITTY_CONF" "$KITTY_CONF.kitty-extensions.bak"

# Drop our own block from a previous run so this stays idempotent (leaves any
# other module's block untouched).
tmp="$(mktemp)"
awk -v m="$MARK" '
  $0 ~ ("^# >>> " m) { skip=1; next }
  skip==1 && $0 ~ ("^# <<< " m) { skip=0; next }
  skip!=1 { print }
' "$KITTY_CONF" > "$tmp" && mv "$tmp" "$KITTY_CONF"

MISSING=()
add_if_missing() { grep -qE "$1" "$KITTY_CONF" || MISSING+=("$2"); }
# allow_remote_control is shared with session-restore; added by whichever
# module installs first, skipped by the other.
add_if_missing '^[[:space:]]*allow_remote_control[[:space:]]+' 'allow_remote_control yes'
add_if_missing '^[[:space:]]*listen_on[[:space:]]+'            'listen_on unix:/tmp/mykitty-{kitty_pid}'
add_if_missing '^[[:space:]]*enabled_layouts[[:space:]]+'      'enabled_layouts splits,stack'

if [ "${#MISSING[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# >>> $MARK (added by install.sh) >>>"
    printf '%s\n' "${MISSING[@]}"
    echo "# <<< $MARK <<<"
  } >> "$KITTY_CONF"
  say "added ${#MISSING[@]} setting(s); backup at $KITTY_CONF.kitty-extensions.bak"
else
  say "kitty.conf already has the shim settings"
fi

# --------------------------------------------------------------------------- #
section "Done (tmux-shim)"
say "Restart kitty (quit fully, then reopen) so kitty.conf takes effect."
say "Run 'claude-kitty' (with any claude args) instead of 'claude' for split-pane teammates."
