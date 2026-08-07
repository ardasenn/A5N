#!/bin/zsh
# A5N monthly digest driver. Runs digest.py, commits the result, and, unlike
# every other job here, NOTIFIES ON SUCCESS: the digest exists to make
# accumulated value visible, so its arrival is the one event worth
# announcing. Failure notifies too.
#
# Shares the .lock with ingest and lint so it can never race their commits.
# An optional YYYY-MM argument is passed through to digest.py.
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
mkdir -p "$LOGDIR"
LOG="$LOGDIR/digest-$(date +%F).log"
LOCK="$LOGDIR/.lock"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

notify() {
  # $1 = message, $2 = empty for info or "fail"
  log "${2:+FAILED: }$1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N digest\"" >/dev/null 2>&1
  fi
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
    log "WARNING: stale lock (${LOCK_AGE}s), removing and continuing"
    rm -f "$LOCK"
  else
    # Not silent on purpose: the digest exists to make things visible, and
    # a silently skipped month looks identical to a broken pipeline. The
    # 09:37 slot can legitimately collide with a long first-of-month
    # ingest, which may hold the shared lock for hours.
    notify "another job holds the lock (${LOCK_AGE}s, probably the ingest), digest skipped; run scripts/digest.sh by hand"
    exit 0
  fi
fi
trap 'rm -f "$LOCK"' EXIT
touch "$LOCK"

cd "$VAULT" || exit 1

# Manual edits stay out of the digest commit, same rule as the other jobs.
if [ -n "$(git status --porcelain)" ]; then
  log "WARNING: vault dirty before digest, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-digest $(date +%F))" >> "$LOG" 2>&1
fi

if ! REL_PATH="$(python3 "$SCRIPT_DIR/digest.py" "$@" 2>>"$LOG")"; then
  notify "digest failed, see .a5n-logs/digest-$(date +%F).log" fail
  git checkout -- . 2>/dev/null
  exit 1
fi
log "digest written: $REL_PATH"

if [ -n "$(git status --porcelain)" ]; then
  PERIOD="${${REL_PATH:t}%.md}"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: digest $PERIOD" >> "$LOG" 2>&1
  log "committed"
fi

notify "monthly digest ready: $REL_PATH"
exit 0
