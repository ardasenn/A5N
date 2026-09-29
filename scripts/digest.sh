#!/bin/zsh
# A5N monthly digest driver. Runs digest.py, commits the result, and, unlike
# every other job here, NOTIFIES ON SUCCESS: the digest exists to make
# accumulated value visible, so its arrival is the one event worth
# announcing. Failure notifies too.
#
# Shares the .lock with ingest and lint so it can never race their commits.
# An optional YYYY-MM argument is passed through to digest.py.

# What the user's .zshenv set, options, aliases, functions and a float
# SECONDS, goes before the lock and sync code loads: daily-ingest.sh has the
# failures behind this.
emulate -R zsh
unalias -m '*'
unfunction -m '*' 2>/dev/null
typeset -i SECONDS
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

trap lock_release EXIT
# A stop from the service manager arrives as TERM, and zsh skips the EXIT
# trap when a signal it does not trap ends it: the lock stayed behind, and
# systemd counts a oneshot killed by a signal as failed. Exiting from a
# trap runs the EXIT trap, with a status the unit reads as a stop. The waits
# for the local lock and for the remote made that window hours long. INT
# and HUP are the same stop for a run started by hand.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# The lock the three jobs share; lib/common.sh has its rules and the reason
# for the wait.
if ! lock_wait digest; then
  # Not silent on purpose: the digest exists to make things visible, and a
  # silently skipped month looks identical to a broken pipeline. Its slot on
  # the first of the month can collide with a long ingest, and a catch-up
  # at boot with the ingest and the lint that start with it.
  notify "another job holds the lock (pid ${LOCK_PID:-?}, ${LOCK_AGE}s) after a ${LOCK_WAIT}s wait, probably a long ingest, digest skipped; run scripts/digest.sh by hand"
  exit 0
fi

# A unit whose driver still runs stops the digest before its own checks can
# end it and remove the lock that has to go back (as in daily-ingest.sh).
unit_driver_runs && exit 0

cd "$VAULT" || exit 1

# Before anything writes: with sync, A5N's own interrupted rebase is undone
# and a user's unfinished git operation or another branch stops the run;
# then a unit a killed run left half written goes to the stash, so the
# commit below cannot sweep it in as manual edits. A unit whose driver still
# runs stops this run instead, the way a lock held too long skips it.
sync_recover || exit 0
recover_interrupted_unit
case $? in
  1) exit 1 ;;
  2) exit 0 ;;
esac

# Manual edits stay out of the digest commit, same rule as the other jobs.
commit_manual_changes digest

# The digest counts the vault's history, so it pulls first: the other
# machine's sessions belong in the numbers. No remote lock and no raw
# download: it only writes digests/, and only one machine runs it. A vault
# that changed under the wait for the remote stops it untouched.
sync_begin digest no no || exit 0
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
