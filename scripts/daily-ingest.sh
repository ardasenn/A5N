#!/bin/zsh
# A5N daily ingest driver. Meant to be run by a scheduler, but running it by
# hand does exactly the same thing.
#
# ARCHITECTURE. An earlier design ran one big headless agent that did
# discovery, dedup, copying, page writing and a result signature, with a
# wholesale rollback on failure. Every week it produced a new choreography
# failure: a background wait ceiling cut finished runs, a backticked
# signature line voided twelve processed sessions, a turn ending killed work
# in flight and the rollback threw away a full day. The principle now:
# ORCHESTRATION IS DETERMINISTIC, THE MODEL ONLY WORKS AT THE LEAF.
#
#   Layer 1  capture: ingest-discover.py capture (pure Python, no LLM).
#            New raws plus deterministic skip lines, one commit. This is the
#            only time critical work (agents delete transcripts after ~30
#            days); page writing has no deadline.
#   Layer 2  processing: one INDEPENDENT, synchronous claude -p worker PER
#            SESSION from the queue (subagents and scheduling disallowed).
#            The moment a unit finishes, ingest-verify.py checks the
#            ARTIFACT (no signature, no claim). Pass: the unit is committed
#            IMMEDIATELY. Fail: only THAT unit's leftovers are reset,
#            sibling units are already safe in their own commits. A failed
#            unit stays queued and retries tomorrow by itself (state is the
#            vault: raw present with no id trace means queued).
#
#   On an empty day the model is never invoked. Silence is success, a
#   notification only fires on failure.
#
# Every setting comes from config.ini through scripts/config.py. Without a
# config file this script refuses to start, which is what keeps a checkout of
# A5N from touching a real vault by accident.
#
# Testing: point A5N_CONFIG at a scratch config, and use A5N_MAX_UNITS /
# A5N_UNIT_TIMEOUT / A5N_NO_NOTIFY to keep the run small and quiet.
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
UNIT_PROMPT_FILE="${A5N_PROMPT_FILE:-$REPO/scripts/prompts/ingest-unit.md}"
# Wall clock per unit. There is no separate ceiling for the whole run: total
# time is already bounded by max_units * unit_timeout.
UNIT_TIMEOUT="${A5N_UNIT_TIMEOUT:-1800}"
CONDENSE_BYTES=$(( ${A5N_CONDENSE_KB:-2048} * 1024 ))

mkdir -p "$LOGDIR/condensed"
LOG="$LOGDIR/$(date +%F).log"
LOCK="$LOGDIR/.lock"
OUT="$LOGDIR/.last-unit-stdout"
QTSV="$LOGDIR/.queue.tsv"
WATCHDOG_FLAG="$LOGDIR/.watchdog-fired"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Silent failure is the known trap in unattended runs. Real failures must be
# visible.
notify_fail() {
  log "FAILED: $1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N ingest\"" >/dev/null 2>&1
  fi
}

# Undo a failed unit's leftovers. The unit started on a clean tree and its
# siblings were committed immediately, so the scope is AT MOST one unit. The
# old "wipe a finished day" risk is structurally gone. (.a5n-logs is
# gitignored, clean -fd does not touch logs or condensed skeletons.)
rollback_unit() {
  git reset --hard --quiet >> "$LOG" 2>&1
  git clean -fd --quiet >> "$LOG" 2>&1
}

# Launch one headless worker in the background, pid in AGENT_PID. The engine
# comes from config.ini [runner]; both drivers dispatch the same way.
start_worker() {
  local effort=()
  if [ "$A5N_RUNNER_ENGINE" = "codex" ]; then
    # codex exec has no per-tool disallow list; the prompt rules plus the
    # mechanical artifact verification carry that weight instead.
    # workspace-write confines writes to the cwd, which is the vault.
    [ -n "$A5N_RUNNER_EFFORT" ] && effort=(-c "model_reasoning_effort=$A5N_RUNNER_EFFORT")
    "$A5N_RUNNER_BIN" exec \
      --sandbox workspace-write \
      --skip-git-repo-check \
      -m "$A5N_RUNNER_MODEL" \
      "${effort[@]}" \
      "$1" > "$OUT" 2>&1 < /dev/null &
  else
    [ -n "$A5N_RUNNER_EFFORT" ] && effort=(--effort "$A5N_RUNNER_EFFORT")
    "$A5N_RUNNER_BIN" -p "$1" \
      --model "$A5N_RUNNER_MODEL" \
      "${effort[@]}" \
      --permission-mode acceptEdits \
      --max-turns 80 \
      --disallowedTools "Agent" "Task" "ScheduleWakeup" "Workflow" "Bash(git commit:*)" "Bash(git push:*)" \
      > "$OUT" 2>&1 < /dev/null &
  fi
  AGENT_PID=$!
}

if [ ! -d "$VAULT/.git" ]; then
  echo "vault is not a git repository: $VAULT" >&2
  echo "run scripts/setup.sh first" >&2
  exit 1
fi

# A stale lock swallows every later run in silence. A crash or hard reboot
# cannot run the exit trap, so a lock older than two hours is dead: in a
# healthy run the lock is refreshed after every unit and can never age that
# much while alive.
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

if [ ! -s "$UNIT_PROMPT_FILE" ]; then
  notify_fail "unit prompt missing or empty ($UNIT_PROMPT_FILE), run cancelled"
  exit 1
fi

# Hand written vault edits should not be mixed into ingest commits. Commit
# them separately under an honest message.
if [ -n "$(git status --porcelain)" ]; then
  log "WARNING: vault dirty before ingest, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-ingest $(date +%F))" >> "$LOG" 2>&1
fi

# ---- Layer 1: capture (deterministic) --------------------------------------
log "layer 1: capture started"
if ! python3 "$SCRIPT_DIR/ingest-discover.py" capture >> "$LOG" 2>&1; then
  # A capture failure is a data risk (the transcript deletion clock is
  # ticking), so it is loud.
  notify_fail "capture layer failed, see .a5n-logs/$(date +%F).log"
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: raw capture $(date +%F)" >> "$LOG" 2>&1
  log "raw capture committed"
fi

# ---- Layer 2: one worker per unit ------------------------------------------
python3 "$SCRIPT_DIR/ingest-discover.py" queue > "$QTSV" 2>> "$LOG"
if [ ! -s "$QTSV" ]; then
  log "queue empty, model never invoked, healthy day"
  exit 0
fi

OK=0; FAIL=0; CONSEC_ERR=0
while IFS=$'\t' read -r PROJ SID RAWP SIZE SDATE; do
  [ -z "${PROJ:-}" ] && continue
  log "unit started: $PROJ/$SID (${SIZE}B, $SDATE)"

  READP="$RAWP"
  if [ "$SIZE" -gt "$CONDENSE_BYTES" ]; then
    READP="$LOGDIR/condensed/$SID.txt"
    if ! python3 "$SCRIPT_DIR/condense-transcript.py" "$RAWP" "$READP" >> "$LOG" 2>&1; then
      log "condense failed: $PROJ/$SID, unit skipped, retries tomorrow"
      FAIL=$((FAIL+1)); continue
    fi
  fi

  PROMPT="$(python3 - "$UNIT_PROMPT_FILE" "$PROJ" "$SID" "$RAWP" "$READP" "$SDATE" "$A5N_LANGUAGE" <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
for k, v in zip(("__PROJECT__", "__SESSION_ID__", "__RAW__", "__READ__",
                 "__DATE__", "__LANGUAGE__"), sys.argv[2:8]):
    t = t.replace(k, v)
sys.stdout.write(t)
PYEOF
)"

  # At most two attempts per unit: when a verification rejection names a
  # fixable cause (a missing id trace, an out of schema path), the second
  # attempt carries the reasons in its prompt, so model compliance variance
  # closes within the run instead of the queue chewing on the same unit for
  # days. Observed: of five same shaped units, two passed first try and
  # three had skipped the full id trace.
  UNIT_DONE=""; VREASON=""
  for ATTEMPT in 1 2; do
    FULL_PROMPT="$PROMPT"
    if [ "$ATTEMPT" -eq 2 ]; then
      FULL_PROMPT="$PROMPT

YOUR PREVIOUS ATTEMPT WAS REJECTED BY VERIFICATION AND ROLLED BACK. The
rejection reasons:
$VREASON

Fix these: write the missing trace or file (write the session id IN FULL),
leave no out of schema path. Every other rule still applies."
      log "attempt 2 (rejection reasons added to the prompt): $PROJ/$SID"
    fi

    # One synchronous worker. stdin from /dev/null so the worker cannot eat
    # the while-read loop's queue.
    rm -f "$WATCHDOG_FLAG"
    start_worker "$FULL_PROMPT"
    # If TERM is swallowed, wait never returns. Thirty second grace, then KILL.
    (
      sleep "$UNIT_TIMEOUT"
      kill -TERM "$AGENT_PID" 2>/dev/null || exit 0
      touch "$WATCHDOG_FLAG"
      sleep 30
      kill -KILL "$AGENT_PID" 2>/dev/null
    ) &
    WATCHDOG_PID=$!
    wait "$AGENT_PID"; AGENT_EXIT=$?
    kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""
    cat "$OUT" >> "$LOG"

    if [ "$AGENT_EXIT" -ne 0 ]; then
      # Infrastructure failure (timeout or API), no in run retry, tomorrow.
      if [ -e "$WATCHDOG_FLAG" ]; then
        log "unit cut at the ${UNIT_TIMEOUT}s ceiling: $PROJ/$SID, rolled back, retries tomorrow"
      else
        log "agent exit=$AGENT_EXIT: $PROJ/$SID, rolled back"
        CONSEC_ERR=$((CONSEC_ERR+1))
      fi
      rollback_unit
      break
    fi
    CONSEC_ERR=0

    VREASON="$(python3 "$SCRIPT_DIR/ingest-verify.py" "$PROJ" "$SID" 2>&1)"
    VEXIT=$?
    echo "$VREASON" >> "$LOG"
    if [ "$VEXIT" -eq 0 ]; then
      git add -A >> "$LOG" 2>&1
      if git commit -m "chore: ingest($PROJ) ${SID:0:8} $SDATE" >> "$LOG" 2>&1; then
        UNIT_DONE=1; log "unit done and committed: $PROJ/$SID (attempt $ATTEMPT)"
      else
        notify_fail "git commit failed ($PROJ/$SID), run stopped, look by hand"
        exit 1
      fi
      break
    fi
    log "verification REJECTED (attempt $ATTEMPT): $PROJ/$SID, rolled back"
    rollback_unit
  done

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), run stopped, queue waits for tomorrow"
      break
    fi
  fi
  touch "$LOCK"
done < "$QTSV"

log "run finished: $OK done, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  notify_fail "$FAIL units unprocessed ($OK done), still queued, they retry tomorrow automatically"
fi
exit 0
