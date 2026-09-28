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
  # stdout too: a hand run should say what happened without opening the log.
  print -r -- "$1"
  log "${2:+FAILED: }$1"
  a5n_desktop_notify "A5N digest" "$1"
}
notify_fail() { notify "$1" fail; }

# Shared with the other drivers: the notification itself and the
# interrupted unit flag.
source "$SCRIPT_DIR/lib/common.sh"

# Keeps the vault in step with other machines; every call is a no-op while
# [sync] is off.
source "$SCRIPT_DIR/lib/sync.sh"

if [ ! -d "$VAULT/.git" ]; then
  echo "vault is not a git repository: $VAULT" >&2
  echo "run scripts/setup.sh first" >&2
  exit 1
fi

if [ -e "$LOCK" ]; then
  LOCK_PID="$(cat "$LOCK" 2>/dev/null)"
  # GNU stat -f means "filesystem status", not mtime, and prints that block to
  # stdout even while it exits nonzero — so the BSD-first order fed filesystem
  # text to the arithmetic below and killed every run (Linux, 2026-08-23..25:
  # three silent ingest failures behind one stale lock). GNU first, BSD second,
  # and a digit guard so no platform can poison the math again. An unreadable
  # mtime counts as fresh: clearing a live owner is worse than one skipped run,
  # and the pid check above is what actually clears a dead owner.
  LOCK_MTIME="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null)"
  [[ "$LOCK_MTIME" == <-> ]] || LOCK_MTIME="$(date +%s)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [[ "$LOCK_PID" == <-> ]] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
    log "WARNING: stale lock (owner pid $LOCK_PID is dead), removing and continuing"
    rm -f "$LOCK"
  elif [ "$LOCK_AGE" -gt 7200 ]; then
    log "WARNING: stale lock (${LOCK_AGE}s), removing and continuing"
    rm -f "$LOCK"
  else
    # Not silent on purpose: the digest exists to make things visible, and
    # a silently skipped month looks identical to a broken pipeline. The
    # 09:37 slot can legitimately collide with a long first-of-month
    # ingest, which may hold the shared lock for hours.
    notify "another job holds the lock (pid ${LOCK_PID:-?}, ${LOCK_AGE}s, probably the ingest), digest skipped; run scripts/digest.sh by hand"
    exit 0
  fi
fi
trap 'rm -f "$LOCK"' EXIT
print -r -- $$ > "$LOCK"

cd "$VAULT" || exit 1

# Before anything writes: with sync, A5N's own interrupted rebase is undone
# and a user's unfinished git operation or another branch stops the run;
# then a unit a killed run left half written goes to the stash, so the
# commit below cannot sweep it in as manual edits.
sync_recover || exit 0
recover_interrupted_unit || exit 1

# Manual edits stay out of the digest commit, same rule as the other jobs.
if [ -n "$(git status --porcelain)" ]; then
  log "WARNING: vault dirty before digest, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-digest $(date +%F))" >> "$LOG" 2>&1
fi

# The digest counts the vault's history, so it pulls first: the other
# machine's sessions belong in the numbers. No remote lock and no raw
# download: it only writes digests/, and only one machine runs it.
sync_begin digest no no
case "$SYNC_STATE" in
  offline)
    notify "digest skipped: $A5N_SYNC_REMOTE unreachable, and a digest without the other machine's work would be wrong; run scripts/digest.sh by hand later" fail
    exit 0 ;;
  blocked) exit 0 ;;
esac

UNIT_BASE="$(git rev-parse HEAD)"
unit_begin "digest"
if ! REL_PATH="$(python3 "$SCRIPT_DIR/digest.py" "$@" 2>>"$LOG")"; then
  notify "digest failed, see .a5n-logs/digest-$(date +%F).log" fail
  git checkout -- . 2>/dev/null
  unit_end
  exit 1
fi
log "digest written: $REL_PATH"

if [ -n "$(git status --porcelain)" ]; then
  PERIOD="${${REL_PATH:t}%.md}"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: digest $PERIOD" >> "$LOG" 2>&1
  log "committed"
fi
unit_end
sync_push_unit "$UNIT_BASE"
case $? in
  2)
    notify "digest dropped after a conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH; run scripts/digest.sh by hand" fail
    exit 1 ;;
  1) log "digest committed, it goes out with the next push" ;;
esac

notify "monthly digest ready: $REL_PATH"
exit 0
