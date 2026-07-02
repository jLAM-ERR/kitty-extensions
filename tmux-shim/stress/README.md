# Split-pane stress test

A load/regression harness for the `tmux` shim's **external-session ("swarm")
mode** — the path Claude Code drives when it opens agent-team teammate panes
(see the repo root README and `CLAUDE.md`).

It replays CC's exact swarm lifecycle against the real shim, at scale, and
asserts the split-pane invariants on every round:

```
display-message -p '#{pane_id}'      anchor (must be non-empty)
has-session -t <sess>                honest not-exist -> rc 1
new-session  ... -P -F '#{pane_id}'  first teammate pane, id parsed back
split-window ... -P -F '#{pane_id}'  one kitty split per further teammate
select-pane  -t %id -T <name>        focus + title
respawn-pane -k -t %id -- <cmd>      swap the real command into the pane
list-panes   -t <sess>               pane count MUST equal PANES
kill-session -t <sess>               teardown
```

## Isolation — it never touches your real setup

- **No real kitty windows open.** `fake-kitten` stands in for `kitten @`: it
  hands back monotonic window ids for `launch` and a shell-prompt glyph for
  `get-text` (so the shim's `wait_for_prompt` returns immediately), and silently
  succeeds for everything else. The shim is pointed at it via
  `KITTY_TMUX_SHIM_BIN`.
- **No pollution of the live install.** `$HOME` is redirected to a throwaway
  sandbox, so the shim's real `~/.claude/kitty-tmux-shim/{shim.log,state.json}`
  are never written.

All run artifacts (`sandbox*/`, `*.counter`, `stress-*.out`,
`stress-summary.txt`) are git-ignored.

## Usage

```bash
./stress.sh                                  # defaults: 8 panes/round, 30 min cap
ROUNDS=50 PANES=4 ./stress.sh                # bounded run
PANES=16 ROUNDS=15 ./stress.sh               # wide splits
DURATION=60 ./stress.sh                      # time-capped
```

Knobs (env vars): `ROUNDS`, `PANES`, `DURATION` (seconds), `SANDBOX`, `REPO`
(defaults to the parent dir, i.e. the repo root — override to test a shim
elsewhere). The run stops at whichever of `ROUNDS` / `DURATION` comes first and
prints a `RESULT: PASS/FAIL` summary.

Requirements: `python3` and `bash` — same as the shim itself. No third-party
dependencies, no real kitty needed.

## What counts as a failure

- Any round where a pane id comes back empty/`0`/non-numeric, or `list-panes`
  doesn't report exactly `PANES` panes.
- Any `UNHANDLED` / `HANDLER EXC` / `unexpected output` / `could not resolve`
  line in the sandbox `shim.log`.

### Built-in regression guard

Before the loop, a one-shot preflight verifies `kill-session -t <sess>` is
**scoped**: it creates two sessions, kills one, and asserts the other survives
intact. The per-round loop only ever has one session alive, so it can't catch a
regression where `kill-session` reverts to wiping *all* sessions — this can, and
aborts the run with `PREFLIGHT FAIL` if the scoping breaks.
