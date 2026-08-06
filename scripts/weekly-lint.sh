#!/bin/zsh
# A5N weekly lint. Two layers:
#
#   1. Mechanical, deterministic. fix-links.py repairs wrong path links, which
#      is the only automatic edit in the whole system. lint-mech.py scans for
#      dead links and orphan pages and writes a report.
#   2. Semantic, run by the headless agent. Contradictions, missing cross
#      references, concepts without a page, schema drift in frontmatter.
#      Reported only, never auto fixed: deciding what to change is yours.
#
# Same proven shape as daily-ingest.sh: lock, stale lock recovery, watchdog,
# signature contract, notification and rollback on failure. Both scripts share
# one lock file so they can never overlap.
set -u

SCRIPT_DIR="${0:A:h}"
REPO="${SCRIPT_DIR:h}"

if ! CONFIG_EXPORTS="$(python3 "$SCRIPT_DIR/config.py" --sh 2>&1)"; then
  echo "$CONFIG_EXPORTS" >&2
  exit 1
fi
eval "$CONFIG_EXPORTS"

VAULT="$A5N_VAULT"
LOGDIR="$VAULT/.a5n-logs"
MECHDIR="$LOGDIR/lint-mech"
PROMPT_FILE="${A5N_LINT_PROMPT_FILE:-$REPO/scripts/prompts/weekly-lint.md}"
RUN_TIMEOUT="$A5N_RUN_TIMEOUT"

mkdir -p "$LOGDIR" "$MECHDIR"
LOG="$LOGDIR/lint-$(date +%F).log"
LOCK="$LOGDIR/.lock"
OUT="$LOGDIR/.last-lint-stdout"
WATCHDOG_FLAG="$LOGDIR/.lint-watchdog-fired"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

notify_fail() {
  log "FAILED: $1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N lint failed\"" >/dev/null 2>&1
  fi
}

rollback_agent_work() {
  git reset --hard --quiet >> "$LOG" 2>&1
  git clean -fd --quiet >> "$LOG" 2>&1
  log "agent leftovers reverted (reset --hard + clean -fd)"
}

if [ ! -d "$VAULT/.git" ]; then
  echo "vault is not a git repository: $VAULT" >&2
  echo "run scripts/setup.sh first" >&2
  exit 1
fi

if [ -e "$LOCK" ]; then
  LOCK_MTIME="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [ "$LOCK_AGE" -gt 7200 ]; then
    log "WARNING: stale lock found (${LOCK_AGE}s), removing and continuing"
    rm -f "$LOCK"
  else
    log "lock held (${LOCK_AGE}s), run skipped"
    exit 0
  fi
fi

cleanup() {
  rm -f "$LOCK"
  [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT
touch "$LOCK"

cd "$VAULT" || exit 1

PROMPT="$(cat "$PROMPT_FILE" 2>/dev/null)"
if [ ! -s "$PROMPT_FILE" ] || [ -z "$PROMPT" ]; then
  notify_fail "lint prompt missing or empty ($PROMPT_FILE), run cancelled"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  log "WARNING: vault dirty before lint, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-lint $(date +%F))" >> "$LOG" 2>&1
fi

log "mechanical layer started"
python3 "$SCRIPT_DIR/fix-links.py" >> "$LOG" 2>&1
python3 "$SCRIPT_DIR/lint-mech.py" "$MECHDIR" >> "$LOG" 2>&1

log "semantic layer started (wall clock ${RUN_TIMEOUT}s)"
rm -f "$WATCHDOG_FLAG"

CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$A5N_CLAUDE_BIN" -p "$PROMPT" \
  --model "$A5N_MODEL" \
  --permission-mode acceptEdits \
  --max-turns 200 \
  > "$OUT" 2>&1 &
AGENT_PID=$!

(
  sleep "$RUN_TIMEOUT"
  kill -TERM "$AGENT_PID" 2>/dev/null || exit 0
  touch "$WATCHDOG_FLAG"
  sleep 30
  kill -KILL "$AGENT_PID" 2>/dev/null
) &
WATCHDOG_PID=$!

wait "$AGENT_PID"
AGENT_EXIT=$?
kill "$WATCHDOG_PID" 2>/dev/null
cat "$OUT" >> "$LOG"
log "agent exit=$AGENT_EXIT"

if [ "$AGENT_EXIT" -ne 0 ]; then
  if [ -e "$WATCHDOG_FLAG" ]; then
    notify_fail "wall clock of ${RUN_TIMEOUT}s reached, lint cut short, work reverted"
  else
    notify_fail "agent exit=$AGENT_EXIT, skipping commit"
  fi
  rollback_agent_work
  exit 1
fi

SIGNATURE="$(grep -a '^LINT_RESULT:' "$OUT" | tail -1)"
if [ -z "$SIGNATURE" ]; then
  notify_fail "no LINT_RESULT signature, the agent did not run. Output: $(tail -c 200 "$OUT")"
  rollback_agent_work
  exit 1
fi
log "$SIGNATURE"

if [ -n "$(git status --porcelain)" ]; then
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: weekly lint $(date +%F)" >> "$LOG" 2>&1
  log "committed"
else
  log "nothing changed, no commit"
fi

log "done"
