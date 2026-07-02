#!/usr/bin/env bash
#
# Top-level installer for kitty-extensions. Dispatches to the self-contained
# per-module installers, so you can install either extension independently:
#
#   1) tmux-shim        Claude Code split-pane teammates on kitty  (any OS + kitty + python3)
#   2) session-restore  reopen previous tabs/splits on launch      (macOS for the LaunchAgent)
#
# Usage:
#   ./install.sh                 # prompt (or install both when non-interactive)
#   ./install.sh all             # both
#   ./install.sh tmux-shim       # just the shim + launcher
#   ./install.sh session-restore # just session restore
#
# Each module's own installer (tmux-shim/install.sh, session-restore/install.sh)
# is idempotent, backs up kitty.conf, and manages only its own kitty.conf block.
# Path overrides (BIN_DIR, KITTY_DIR, ...) are passed straight through as env vars.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

run_module() {  # <module-dir>
  echo
  echo "############################################################"
  echo "# $1"
  echo "############################################################"
  bash "$REPO/$1/install.sh"
}

choice="${1:-}"

if [ -z "$choice" ]; then
  if [ -t 0 ]; then
    echo "kitty-extensions installer -- what would you like to install?"
    echo "  1) tmux-shim        (Claude Code split-pane teammates)"
    echo "  2) session-restore  (reopen tabs/splits on launch; macOS)"
    echo "  3) both"
    printf 'Choice [3]: '
    read -r n
    case "${n:-3}" in
      1) choice=tmux-shim ;;
      2) choice=session-restore ;;
      3|"") choice=all ;;
      *) echo "Unrecognized choice: $n" >&2; exit 1 ;;
    esac
  else
    # Non-interactive (e.g. piped): default to installing everything.
    choice=all
  fi
fi

case "$choice" in
  tmux-shim)        run_module tmux-shim ;;
  session-restore)  run_module session-restore ;;
  all)              run_module tmux-shim; run_module session-restore ;;
  -h|--help|help)   usage; exit 0 ;;
  *) echo "Unknown target: $choice" >&2; echo >&2; usage >&2; exit 1 ;;
esac

echo
echo "==> All requested modules installed. Restart kitty for kitty.conf to take effect."
