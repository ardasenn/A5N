#!/bin/zsh
# A5N weekly lint driver. Same two layer pattern as daily-ingest.sh: the
# result signature contract is gone, replaced by PER PROJECT independent
# workers, mechanical artifact verification and per unit commits. A failing
# project cannot take the other projects' reports down with it, and a
# verification rejection feeds its reasons into a second attempt.
#
# Flow:
#   1. fix-links.py   repairs wrong path links (deterministic, the only
#                     automatic edit in the whole system)
#   2. lint-mech.py   dead link and orphan scan (.a5n-logs/lint-mech/)
#      -> mechanical changes get their own commit
#   3. one claude -p semantic lint worker per project (no subagents,
#      report only)
#      -> verification: the changed paths are EXACTLY <project>/lint-report.md
#         and <project>/log.md, and the report must have changed. A passing
#         project is committed immediately.
#
# The lint shares ONE lock file with the ingest, so they can never overlap.
# If the ingest is still running, the lint notifies and leaves.
#
# Testing: point A5N_CONFIG at a scratch config, and use A5N_LINT_PROJECTS
# ("acme-shop other" narrows the project list) / A5N_UNIT_TIMEOUT /
# A5N_NO_NOTIFY.
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
UNIT_TIMEOUT="${A5N_UNIT_TIMEOUT:-1800}"

mkdir -p "$LOGDIR" "$MECHDIR"
LOG="$LOGDIR/lint-$(date +%F).log"
LOCK="$LOGDIR/.lock"
OUT="$LOGDIR/.last-lint-stdout"
WATCHDOG_FLAG="$LOGDIR/.lint-watchdog-fired"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

notify_fail() {
  log "FAILED: $1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N lint\"" >/dev/null 2>&1
  fi
}

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

# The lock is SHARED with daily-ingest. Staleness has two signals: a dead
# owner pid inside the lock (a killed driver cannot run its exit trap),
# or an mtime older than two hours — a healthy run refreshes the lock
# after every unit, so a live lock can never age that much. An empty pid
# means an older lock format; the age rule covers it.
if [ -e "$LOCK" ]; then
  LOCK_PID="$(cat "$LOCK" 2>/dev/null)"
  LOCK_MTIME="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [[ "$LOCK_PID" == <-> ]] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
    log "WARNING: stale lock (owner pid $LOCK_PID is dead), removing and continuing"
    rm -f "$LOCK"
  elif [ "$LOCK_AGE" -gt 7200 ]; then
    log "WARNING: stale lock (${LOCK_AGE}s), removing and continuing"
    rm -f "$LOCK"
  else
    notify_fail "lock held by pid ${LOCK_PID:-?} (${LOCK_AGE}s, probably the ingest is running), lint skipped; by hand: scripts/weekly-lint.sh"
    exit 0
  fi
fi
cleanup() {
  rm -f "$LOCK"
  [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT
print -r -- $$ > "$LOCK"

cd "$VAULT" || exit 1

if [ ! -s "$PROMPT_FILE" ]; then
  notify_fail "lint prompt missing or empty ($PROMPT_FILE), run cancelled"
  exit 1
fi

# Hand written edits should not be mixed into lint commits.
if [ -n "$(git status --porcelain)" ]; then
  log "WARNING: vault dirty before lint, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-lint $(date +%F))" >> "$LOG" 2>&1
fi

# --- 1+2. Mechanical layer (deterministic) ----------------------------------
log "fix-links started"
FIX_OUT="$(python3 "$SCRIPT_DIR/fix-links.py" 2>>"$LOG")"
FIX_RC=$?
echo "$FIX_OUT" >> "$LOG"
if [ "$FIX_RC" -ne 0 ]; then
  notify_fail "fix-links.py failed (rc=$FIX_RC), lint cancelled, leftovers reverted"
  rollback_unit
  exit 1
fi
echo "$FIX_OUT" | head -1 > "$MECHDIR/last-fix-count.txt"

log "lint-mech started"
if ! python3 "$SCRIPT_DIR/lint-mech.py" "$MECHDIR" >> "$LOG" 2>&1; then
  notify_fail "lint-mech.py failed, lint cancelled, leftovers reverted"
  rollback_unit
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: lint mechanical link repairs $(date +%F)" >> "$LOG" 2>&1
  log "mechanical repairs committed"
fi

# --- 3. Semantic lint: one worker per project -------------------------------
# The namespace list is dynamic: every vault root directory holding a
# sources/ folder. A namespace dropped from config.ini still gets linted as
# long as its pages exist.
PROJECTS="${A5N_LINT_PROJECTS:-}"
if [ -z "$PROJECTS" ]; then
  PROJECTS="$(for d in */; do [ -d "${d}sources" ] && echo "${d%/}"; done)"
fi

TODAY="$(date +%F)"
OK=0; FAIL=0; CONSEC_ERR=0
for PROJ in ${=PROJECTS}; do
  log "lint unit started: $PROJ"
  PROMPT="$(python3 - "$PROMPT_FILE" "$PROJ" "$TODAY" "$A5N_LANGUAGE" <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
for k, v in zip(("__PROJECT__", "__DATE__", "__LANGUAGE__"), sys.argv[2:5]):
    t = t.replace(k, v)
sys.stdout.write(t)
PYEOF
)"

  UNIT_DONE=""; VREASON=""
  for ATTEMPT in 1 2; do
    FULL_PROMPT="$PROMPT"
    if [ "$ATTEMPT" -eq 2 ]; then
      FULL_PROMPT="$PROMPT

YOUR PREVIOUS ATTEMPT WAS REJECTED BY VERIFICATION AND ROLLED BACK. The
rejection reasons:
$VREASON

Fix these. Only $PROJ/lint-report.md and $PROJ/log.md may change, and the
report file must have been written."
      log "attempt 2 (rejection reasons added to the prompt): $PROJ"
    fi

    rm -f "$WATCHDOG_FLAG"
    start_worker "$FULL_PROMPT"
    # Same TERM-trapped watchdog as daily-ingest.sh: killing the subshell
    # alone would orphan the external sleep, which holds stdout open and
    # hangs any pipe reading this script's output.
    (
      trap 'kill $! 2>/dev/null; exit 0' TERM
      sleep "$UNIT_TIMEOUT" & wait $!
      kill -TERM "$AGENT_PID" 2>/dev/null || exit 0
      touch "$WATCHDOG_FLAG"
      sleep 30 & wait $!
      kill -KILL "$AGENT_PID" 2>/dev/null
    ) &
    WATCHDOG_PID=$!
    wait "$AGENT_PID"; AGENT_EXIT=$?
    kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""
    cat "$OUT" >> "$LOG"

    if [ "$AGENT_EXIT" -ne 0 ]; then
      if [ -e "$WATCHDOG_FLAG" ]; then
        log "unit cut at the ${UNIT_TIMEOUT}s ceiling: $PROJ, rolled back"
      else
        log "agent exit=$AGENT_EXIT: $PROJ, rolled back"
        CONSEC_ERR=$((CONSEC_ERR+1))
      fi
      rollback_unit
      break
    fi
    CONSEC_ERR=0

    # Artifact verification, mechanical: the changed paths may ONLY be this
    # project's lint-report.md and log.md, and the report MUST have changed.
    # "Report only" is no longer a prompt request but a guarantee.
    VREASON=""
    DIRT="$(git status --porcelain | sed -E 's/^.{3}//; s/^"|"$//g; s/.* -> //')"
    if [ -z "$DIRT" ]; then
      VREASON="tree is clean, the worker wrote no report"
    else
      while IFS= read -r P; do
        case "$P" in
          "$PROJ/lint-report.md"|"$PROJ/log.md") ;;
          *) VREASON="$VREASON path not allowed: $P;" ;;
        esac
      done <<< "$DIRT"
      echo "$DIRT" | grep -qx "$PROJ/lint-report.md" || \
        VREASON="$VREASON $PROJ/lint-report.md unchanged (no report);"
    fi

    if [ -z "$VREASON" ]; then
      git add -A >> "$LOG" 2>&1
      if git commit -m "chore: lint($PROJ) $TODAY" >> "$LOG" 2>&1; then
        UNIT_DONE=1; log "lint unit done and committed: $PROJ (attempt $ATTEMPT)"
      else
        notify_fail "git commit failed (lint $PROJ), run stopped, look by hand"
        exit 1
      fi
      break
    fi
    log "verification REJECTED (attempt $ATTEMPT): $PROJ, $VREASON"
    rollback_unit
  done

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), lint stopped"
      break
    fi
  fi
  touch "$LOCK"
done

log "lint finished: $OK done, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  notify_fail "lint: $FAIL projects unreported ($OK done), they retry next week"
fi
exit 0
