#!/bin/zsh
# A5N daily ingest. Reads new agent transcripts, turns them into vault pages,
# commits the result. Meant to be run by a scheduler, but running it by hand
# does exactly the same thing.
#
# Health contract: the agent must leave an "INGEST_RESULT:" line as the last
# line of stdout (see prompts/daily-ingest.md, section 4). No signature means
# the agent never really ran, so the run counts as failed and nothing is
# committed. A "no-new-sessions" signature is normal: no work, no error.
#
# Every setting comes from config.ini through scripts/config.py. Without a
# config file this script refuses to start, which is what keeps a checkout of
# A5N from touching a real vault by accident.
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
PROMPT_FILE="${A5N_PROMPT_FILE:-$REPO/scripts/prompts/daily-ingest.md}"
RUN_TIMEOUT="$A5N_RUN_TIMEOUT"

mkdir -p "$LOGDIR"
LOG="$LOGDIR/$(date +%F).log"
LOCK="$LOGDIR/.lock"
OUT="$LOGDIR/.last-run-stdout"
WATCHDOG_FLAG="$LOGDIR/.watchdog-fired"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

# Silent failure is the known trap here: an early version logged "committed"
# after a six second run that did nothing. Real failures must be visible.
notify_fail() {
  log "FAILED: $1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N ingest failed\"" >/dev/null 2>&1
  fi
}

# Undo whatever the agent left behind on failure. The tree is always clean
# before the agent starts (see the pre-ingest commit below), so anything dirty
# past that point is agent output, and half finished work must not leak into
# tomorrow's commit.
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

# A stale lock swallows every later run in silence. A crash or hard reboot
# cannot run the exit trap, so treat a lock older than two hours as dead.
if [ -e "$LOCK" ]; then
  LOCK_MTIME="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [ "$LOCK_AGE" -gt 7200 ]; then
    log "WARNING: stale lock found (${LOCK_AGE}s, previous run crashed), removing and continuing"
    rm -f "$LOCK"
  else
    log "lock held (${LOCK_AGE}s), run skipped"
    exit 0
  fi
fi

# If the script dies early the watchdog subshell must not outlive it, or it
# would later try to kill a pid that no longer belongs to us.
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
  notify_fail "prompt file missing or empty ($PROMPT_FILE), run cancelled"
  exit 1
fi

# Hand written vault edits should not be mixed into the ingest commit. Commit
# them separately under an honest message so the agent starts from a clean tree.
if [ -n "$(git status --porcelain)" ]; then
  log "WARNING: vault dirty before ingest, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-ingest $(date +%F))" >> "$LOG" 2>&1
fi

log "ingest started (wall clock ${RUN_TIMEOUT}s)"
rm -f "$WATCHDOG_FLAG"

# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 waits for background subagents without
# a ceiling. The built in 600s ceiling used to cut runs that had already
# finished their work, so the result line was never written and the rollback
# threw good work away. Our own wall clock replaces it, and the watchdog below
# is what keeps an unbounded wait from hanging forever.
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$A5N_CLAUDE_BIN" -p "$PROMPT" \
  --model "$A5N_MODEL" \
  --permission-mode acceptEdits \
  --max-turns 200 \
  > "$OUT" 2>&1 &
AGENT_PID=$!

# If TERM is swallowed, wait never returns. Thirty second grace, then KILL.
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
    notify_fail "wall clock of ${RUN_TIMEOUT}s reached, run cut short, work reverted"
  else
    notify_fail "agent exit=$AGENT_EXIT, skipping commit (a half finished ingest is never committed)"
  fi
  rollback_agent_work
  exit 1
fi

SIGNATURE="$(grep -a '^INGEST_RESULT:' "$OUT" | tail -1)"
if [ -z "$SIGNATURE" ]; then
  notify_fail "no INGEST_RESULT signature, the agent did not run. Output: $(tail -c 200 "$OUT")"
  rollback_agent_work
  exit 1
fi
log "$SIGNATURE"

case "$SIGNATURE" in
  *no-new-sessions*)
    if [ -n "$(git status --porcelain)" ]; then
      notify_fail "agent reported no new sessions but the tree is dirty, unexpected, work reverted"
      rollback_agent_work
      exit 1
    fi
    log "nothing to do, no commit"
    ;;
  *)
    if [ -z "$(git status --porcelain)" ]; then
      notify_fail "agent reported work but nothing changed on disk"
      exit 1
    fi
    git add -A >> "$LOG" 2>&1
    git commit -m "chore: daily ingest $(date +%F)" >> "$LOG" 2>&1
    log "committed"
    ;;
esac

log "done"
