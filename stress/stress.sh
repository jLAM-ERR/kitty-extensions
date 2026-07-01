#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Long split-pane stress test for the kitty-tmux-shim (`tmux`).
#
# Drives the shim through Claude Code's *external-session* ("swarm") sequence
# -- the exact path CC 2.1.x takes when $TMUX is unset -- at scale and asserts
# the split-pane invariants on every round:
#
#   display-message -p '#{pane_id}'      anchor (must be non-empty)
#   has-session -t <sess>                honest not-exist -> rc 1
#   new-session  ... -P -F '#{pane_id}'  first teammate pane, id parsed back
#   split-window ... -P -F '#{pane_id}'  one kitty split per further teammate
#   select-pane  -t %id -T <name>        focus + title
#   respawn-pane -k -t %id -- <cmd>      swap real command into the pane
#   list-panes   -t <sess> -F '#{pane_id}'  pane count MUST equal PANES
#   kill-session -t <sess>               teardown (resets shim state)
#
# It is fully isolated: KITTY_TMUX_SHIM_BIN points at the fake kitten (no real
# kitty windows open), and HOME is a sandbox so the real install's shim.log /
# state.json are never touched.
#
# Env knobs:  ROUNDS (default 100000)  PANES (default 8)  DURATION secs (1800)
#             SANDBOX (default ./sandbox)
# Stops at whichever of ROUNDS / DURATION is hit first.
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# The shim (`tmux`) lives at the repo root; this script lives in stress/.
# Resolve it relative to our own location so the harness is path-independent.
REPO="${REPO:-$(cd "$HERE/.." && pwd)}"
SHIM="$REPO/tmux"

ROUNDS="${ROUNDS:-100000}"
PANES="${PANES:-8}"
DURATION="${DURATION:-1800}"
SANDBOX="${SANDBOX:-$HERE/sandbox}"

SHIMDIR="$SANDBOX/.claude/kitty-tmux-shim"
LOG="$SHIMDIR/shim.log"
SUMMARY="$HERE/stress-summary.txt"
mkdir -p "$SHIMDIR"
: > "$SANDBOX/fake-kitten.counter"

# Isolate the shim entirely from the live install and from real kitty.
export HOME="$SANDBOX"
export KITTY_TMUX_SHIM_BIN="$HERE/fake-kitten"
export KITTY_FAKE_STATE="$SANDBOX"
export KITTY_WINDOW_ID=1            # the "lead" pane the swarm anchors on
unset KITTY_LISTEN_ON TMUX TMUX_PANE 2>/dev/null || true

shim() { python3 "$SHIM" "$@"; }

# Parse the `%<id>` a -P -F '#{pane_id}' command prints back; echo bare id.
paneid() { local o; o="$(shim "$@")"; o="${o%%$'\n'*}"; printf '%s' "${o#%}"; }

# A real kitty window id is a positive integer. The shim prints "%0" for a
# FAILED launch (empty wid) -> id "0"; a caught HANDLER EXC prints nothing.
# Reject both, plus any non-digit, so a bogus id can't pass as success.
is_wid() { case "$1" in '' | 0 | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

start=$SECONDS
rounds=0 fails=0 splits=0

finish() {
    local anomalies
    # grep -c prints a count AND exits 1 when zero matches -- capture, don't `|| echo`.
    anomalies=$(grep -cE 'UNHANDLED|HANDLER EXC| EXC |unexpected output|could not resolve' "$LOG" 2>/dev/null)
    anomalies=${anomalies:-0}
    {
        echo "==== split-pane stress summary ===="
        echo "ended         : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "elapsed       : $((SECONDS - start))s"
        echo "rounds        : $rounds"
        echo "panes/round   : $PANES"
        echo "total splits  : $splits"
        echo "round failures: $fails"
        echo "log anomalies : $anomalies   (UNHANDLED/EXC/unexpected/could-not-resolve)"
        echo "sandbox       : $SANDBOX"
        echo "shim log      : $LOG"
        if [ "$fails" -eq 0 ] && [ "$anomalies" -eq 0 ]; then
            echo "RESULT        : PASS"
        else
            echo "RESULT        : FAIL"
            grep -nE 'UNHANDLED|HANDLER EXC| EXC |unexpected output|could not resolve' "$LOG" 2>/dev/null | head -20
        fi
    } | tee "$SUMMARY"
}
trap finish EXIT INT TERM

# One full swarm lifecycle at scale. Returns non-zero on any invariant breach.
run_round() {
    local r="$1"
    local sess="stress$r"
    local i id n
    local -a ids=()

    shim display-message -p '#{pane_id}' >/dev/null
    shim has-session -t "$sess" >/dev/null 2>&1   # rc 1 expected (fresh name)

    id="$(paneid new-session -d -s "$sess" -n view -P -F '#{pane_id}' -- cat)"
    is_wid "$id" || { echo "FAIL round $r: bad new-session pane id '$id'" >&2; return 1; }
    ids+=("$id"); splits=$((splits + 1))

    for ((i = 1; i < PANES; i++)); do
        id="$(paneid split-window -h -t "$sess:view" -l 50% -P -F '#{pane_id}' -- cat)"
        is_wid "$id" || { echo "FAIL round $r: bad split id '$id' at pane $i" >&2; return 1; }
        ids+=("$id"); splits=$((splits + 1))
    done

    for ((i = 0; i < ${#ids[@]}; i++)); do
        shim select-pane  -t "%${ids[i]}" -T "tm$i"            >/dev/null
        shim respawn-pane -k -t "%${ids[i]}" -- echo "teammate $i" >/dev/null
    done

    n="$(shim list-panes -t "$sess:view" -F '#{pane_id}' | grep -c .)"
    [ "$n" -eq "$PANES" ] || { echo "FAIL round $r: list-panes=$n want=$PANES" >&2; return 1; }

    shim kill-session -t "$sess" >/dev/null
    return 0
}

# One-shot regression guard, run once before the stress loop: `kill-session
# -t <sess>` MUST be scoped -- close only the target session's panes and leave
# a second live session intact. The per-round loop only ever has ONE session
# alive at kill time, so it cannot distinguish a scoped kill from a wipe-all;
# this two-session check can, and fails the whole run loudly if scoping breaks.
preflight_scoped_kill() {
    local n
    paneid new-session  -d -s ck_alpha -P -F '#{pane_id}' -- cat >/dev/null
    paneid split-window    -t ck_alpha -P -F '#{pane_id}' -- cat >/dev/null
    paneid new-session  -d -s ck_beta  -P -F '#{pane_id}' -- cat >/dev/null
    paneid split-window    -t ck_beta  -P -F '#{pane_id}' -- cat >/dev/null
    paneid split-window    -t ck_beta  -P -F '#{pane_id}' -- cat >/dev/null

    shim kill-session -t ck_alpha >/dev/null           # must hit ONLY ck_alpha

    n="$(shim list-panes -t ck_beta -F '#{pane_id}' | grep -c .)"
    if [ "$n" -ne 3 ]; then
        echo "PREFLIGHT FAIL: after 'kill-session -t ck_alpha', ck_beta has $n panes (want 3) -- scoped kill regressed to wipe-all" >&2
        shim kill-session >/dev/null                   # blunt cleanup
        return 1
    fi
    if shim has-session -t ck_alpha >/dev/null 2>&1; then
        echo "PREFLIGHT FAIL: ck_alpha still present after 'kill-session -t ck_alpha'" >&2
        shim kill-session >/dev/null
        return 1
    fi
    shim kill-session -t ck_beta >/dev/null            # scoped cleanup of survivor
    return 0
}

echo "$(date '+%H:%M:%S') starting: PANES=$PANES DURATION=${DURATION}s ROUNDS<=$ROUNDS sandbox=$SANDBOX"
if ! preflight_scoped_kill; then
    fails=$((fails + 1))
    echo "$(date '+%H:%M:%S') preflight: scoped kill-session check FAILED -- aborting run" >&2
    exit 1   # EXIT trap `finish` reports RESULT: FAIL
fi
echo "$(date '+%H:%M:%S') preflight: scoped kill-session OK (two-session teardown)"
while (( rounds < ROUNDS )) && (( SECONDS - start < DURATION )); do
    rounds=$((rounds + 1))
    run_round "$rounds" || fails=$((fails + 1))
    if (( rounds % 50 == 0 )); then
        anomalies=$(grep -cE 'UNHANDLED|HANDLER EXC| EXC |unexpected output|could not resolve' "$LOG" 2>/dev/null)
        anomalies=${anomalies:-0}
        printf '%s rounds=%-6d splits=%-7d fails=%-3d log_anomalies=%-3d elapsed=%ds\n' \
            "$(date '+%H:%M:%S')" "$rounds" "$splits" "$fails" "$anomalies" "$((SECONDS - start))"
    fi
done
# `finish` runs via the EXIT trap.
