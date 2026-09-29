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
# If the ingest is still running, the lint waits for it (lib/common.sh);
# only a wait that runs out makes it notify and leave.
#
# Testing: point A5N_CONFIG at a scratch config, and use A5N_LINT_PROJECTS
# ("acme-shop other" narrows the project list) / A5N_UNIT_TIMEOUT /
# A5N_NO_NOTIFY.

# Every option the user's .zshenv set goes back to zsh's default before the
# lock and sync code loads: daily-ingest.sh has the failures behind this.
emulate -R zsh
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
  a5n_desktop_notify "A5N lint" "$1"
}

# Shared with the other drivers: the notification itself and the
# interrupted unit flag.
source "$SCRIPT_DIR/lib/common.sh"

# Keeps the vault in step with other machines; every call is a no-op while
# [sync] is off.
source "$SCRIPT_DIR/lib/sync.sh"

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

cleanup() {
  sync_lock_release
  lock_release
  [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT
# Stop signals stop the worker, then exit through cleanup, so the remote
# lock is released and no worker outlives it: the reasons are in
# daily-ingest.sh.
stop_worker() { [ -n "${AGENT_PID:-}" ] && kill -TERM "$AGENT_PID" 2>/dev/null; }
trap 'stop_worker; exit 143' TERM
trap 'stop_worker; exit 130' INT
trap 'stop_worker; exit 129' HUP

# The lock is SHARED with daily-ingest; lib/common.sh has its rules and the
# reason for the wait. A lint that still cannot run after the wait says so:
# its next slot is a week away.
if ! lock_wait lint; then
  notify_fail "lock held by pid ${LOCK_PID:-?} (${LOCK_AGE}s) after a ${LOCK_WAIT}s wait, probably a long ingest, lint skipped; by hand: scripts/weekly-lint.sh"
  exit 0
fi

cd "$VAULT" || exit 1

if [ ! -s "$PROMPT_FILE" ]; then
  notify_fail "lint prompt missing or empty ($PROMPT_FILE), run cancelled"
  exit 1
fi

# Before anything writes: with sync, A5N's own interrupted rebase is undone
# and a user's unfinished git operation or another branch stops the run;
# then a unit a killed run left half written goes to the stash, so the
# commit below cannot sweep it in as manual edits.
sync_recover || exit 0
recover_interrupted_unit || exit 1

# Hand written edits should not be mixed into lint commits.
commit_manual_changes lint

# With sync: pull, the raw download, then the remote lock. Every lint step
# edits or reports on pages, so none of it may run next to the other
# machine's workers. The lint already notifies when the local lock makes it
# skip, and these skips follow suit. A vault that changed under the wait
# for the remote, or under the wait for its lock, stops the lint untouched,
# and says so once.
sync_begin lint yes yes || exit 0
case "$SYNC_STATE" in
  offline)
    notify_fail "lint skipped: $A5N_SYNC_REMOTE unreachable; by hand later: scripts/weekly-lint.sh"
    exit 0 ;;
  blocked) exit 0 ;;
esac
sync_ready_for_workers
case $? in
  1)
    notify_fail "lint skipped: $SYNC_SKIP_REASON; by hand later: scripts/weekly-lint.sh"
    exit 0 ;;
  # The vault changed under the wait for the remote lock, and the check that
  # found it has said why already: a second notification adds nothing.
  2) exit 0 ;;
esac

# --- 1+2. Mechanical layer (deterministic) ----------------------------------
UNIT_BASE="$(git rev-parse HEAD)"
unit_begin "lint mechanical repairs"
log "fix-links started"
FIX_OUT="$(python3 "$SCRIPT_DIR/fix-links.py" 2>>"$LOG")"
FIX_RC=$?
echo "$FIX_OUT" >> "$LOG"
if [ "$FIX_RC" -ne 0 ]; then
  notify_fail "fix-links.py failed (rc=$FIX_RC), lint cancelled, leftovers reverted"
  rollback_unit
  unit_end
  exit 1
fi
echo "$FIX_OUT" | head -1 > "$MECHDIR/last-fix-count.txt"

log "lint-mech started"
if ! python3 "$SCRIPT_DIR/lint-mech.py" "$MECHDIR" >> "$LOG" 2>&1; then
  notify_fail "lint-mech.py failed, lint cancelled, leftovers reverted"
  rollback_unit
  unit_end
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: lint mechanical link repairs $(date +%F)" >> "$LOG" 2>&1
  log "mechanical repairs committed"
fi
unit_end
sync_push_unit "$UNIT_BASE"
case $? in
  1)
    log "lint stopped: the remote cannot take pushes now, the commits wait for the next run"
    exit 0 ;;
  2) log "mechanical repairs dropped after a conflict, next week's run redoes them" ;;
esac

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

  UNIT_BASE="$(git rev-parse HEAD)"
  unit_begin "lint $PROJ"
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
    # Reaped, and a reaped pid can be reused: the stop trap must not
    # signal it.
    AGENT_PID=""
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
  unit_end

  # Same rules as the ingest: a conflict drops the report (next week redoes
  # it), an unreachable remote keeps it and stops.
  PUSH_RC=0
  if [ -n "$UNIT_DONE" ]; then
    sync_push_unit "$UNIT_BASE"
    PUSH_RC=$?
    [ "$PUSH_RC" -eq 2 ] && UNIT_DONE=""
  fi

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), lint stopped"
      break
    fi
  fi
  [ "$PUSH_RC" -eq 1 ] && break
  lock_touch
  sync_lock_refresh || break
done

log "lint finished: $OK done, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  notify_fail "lint: $FAIL projects unreported ($OK done), they retry next week"
fi
exit 0
