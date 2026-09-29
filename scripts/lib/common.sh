# Shared by the three run drivers (daily-ingest.sh, weekly-lint.sh,
# digest.sh): what they have in common that is not sync. Sourced, never
# executed. Before sourcing, a driver defines log() and notify_fail() and
# sets LOGDIR, LOG and LOCK; recover_interrupted_unit and
# commit_manual_changes run with the vault as their working directory.

# Desktop notification, $1 title, $2 message. Never fails the run.
a5n_desktop_notify() {
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
    return 0
  fi
  command -v notify-send >/dev/null 2>&1 || return 0
  # A systemd user service inherits the user manager's environment, which
  # normally carries the session bus address. The fallback covers a manager
  # started without it; the socket path is the standard one.
  local bus="${DBUS_SESSION_BUS_ADDRESS:-}"
  if [ -z "$bus" ] && [ -S "/run/user/$(id -u)/bus" ]; then
    bus="unix:path=/run/user/$(id -u)/bus"
  fi
  # With nobody logged in there can be a bus but no notification daemon,
  # and the call may block on D-Bus activation. A notification must never
  # hold a run, and its lock, hostage.
  DBUS_SESSION_BUS_ADDRESS="$bus" timeout 10 notify-send --app-name=A5N "$1" "$2" >/dev/null 2>&1
  return 0
}

UNIT_FLAG="$LOGDIR/.unit-in-progress"

# A unit is everything between a worker's first write and the commit or
# rollback that closes it. The flag marks that window on disk, because a
# killed driver cannot run its exit trap.
unit_begin() {  # <what>, e.g. "ingest alpha/1a2b3c4d"
  print -r -- "$1 | pid $$ | $(date '+%F %T')" > "$UNIT_FLAG"
}

unit_end() {
  rm -f "$UNIT_FLAG"
}

# Run before the "manual changes" commit. A driver killed mid unit (a
# service stopped, a lid closed on a dying battery) leaves half written
# pages, and that commit used to sweep them into history as if a person had
# written them; with sync on it would push them to the other machine too.
# They go to a stash rather than away: the user may have edited the vault by
# hand since the crash, and those edits must survive. 0 go on, 1 stop.
recover_interrupted_unit() {
  [ -e "$UNIT_FLAG" ] || return 0
  local what
  what="$(cat "$UNIT_FLAG" 2>/dev/null)"
  if [ -n "$(git status --porcelain)" ]; then
    if ! git stash push -u -m "a5n: interrupted unit ($what)" >> "$LOG" 2>&1; then
      notify_fail "an interrupted unit ($what) left changes and git stash failed, run stopped, look by hand"
      return 1
    fi
    log "WARNING: interrupted unit ($what), its leftovers moved to git stash"
    notify_fail "a killed run left half written pages ($what); they are in git stash now, with any edit you made by hand since: git stash list"
  else
    log "interrupted unit flag found ($what), tree clean, nothing to recover"
  fi
  rm -f "$UNIT_FLAG"
  return 0
}

# Hand written vault edits never ride in a job's own commits: they get one
# commit of their own under an honest message. A driver calls this before
# its first write, and sync_begin once more after the wait for the remote,
# which can end just as somebody logs in and starts editing. <job>: ingest,
# lint or digest.
commit_manual_changes() {
  [ -n "$(git status --porcelain)" ] || return 0
  log "WARNING: vault dirty before $1, committing manual edits separately"
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: manual vault changes (pre-$1 $(date +%F))" >> "$LOG" 2>&1
}

# --- the local lock -------------------------------------------------------------
# $LOCK, .a5n-logs/.lock, keeps the three jobs apart on this machine: they
# all commit into one git tree. It holds the owner's pid, and the owner
# touches it after every unit and all through its waits for the remote.
#
# A job that finds it taken waits instead of skipping. A timer with
# Persistent=true starts every run the machine was off for about four
# seconds after boot, all at once, and the one that lost the lock was
# skipped until its next slot: a day for the ingest, a week for the lint, a
# month for the digest, because the timer had already recorded the run. On
# 2026-09-28 a lint catch-up held the lock from 08:57 to 09:28; a 09:07
# ingest would have lost its day. Two hours covers an ingest (34 to 95
# minutes seen on a real vault) or a lint (about 30). It is A5N's own
# timing, not the machine's, so it lives here and not in config.ini, like
# the wait for the remote lock. The environment overrides exist for
# tests/sync-e2e.sh.
LOCK_WAIT="${A5N_LOCK_WAIT:-7200}"
LOCK_POLL="${A5N_LOCK_POLL:-10}"
LOCK_STALE=7200
LOCK_GUARD="$LOGDIR/.lock-guard"
LOCK_TAKEN=""        # set once this run holds the lock
LOCK_PID=""          # the owner and the age of the lock last read,
LOCK_AGE=0           # for the drivers' messages
LOCK_STALE_WHY=""

lock_read() {
  local mtime
  LOCK_PID="$(cat "$LOCK" 2>/dev/null)"
  # GNU stat -f means "filesystem status", not mtime, and prints that block
  # to stdout even while it exits nonzero, so the BSD-first order fed
  # filesystem text to the arithmetic below and killed every run (Linux,
  # 2026-08-23..25: three silent ingest failures behind one stale lock). GNU
  # first, BSD second, and a digit guard so no platform can poison the math
  # again. An unreadable mtime counts as fresh: clearing a live owner is
  # worse than a wait, and the pid check is what actually clears a dead
  # owner.
  mtime="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null)"
  [[ "$mtime" == <-> ]] || mtime="$(date +%s)"
  LOCK_AGE=$(( $(date +%s) - mtime ))
}

# Whether pid $1 runs one of the three drivers: -o command= is the whole
# command line on Linux and on macOS. -ww, because procps cuts it to an
# exported COLUMNS even into a pipe, and a cut line hid a running driver.
lock_owner_is_a5n() {
  [[ "$(ps -ww -p "$1" -o command= 2>/dev/null)" == *(daily-ingest|weekly-lint|digest).sh* ]]
}

# A stale lock would swallow every later run. A dead owner pid frees it at
# once: a killed driver cannot run its exit trap, but its pid dies with it
# (seen live when a launchctl bootout mid run left a freshly touched lock
# that blocked runs for two hours). So does this run's own pid in a lock it
# has not taken, left by an earlier process that had the pid: the run used
# to wait for itself. Two hours without a touch free a lock too, but only
# when its pid is no A5N run (another program got a dead owner's pid) or
# when it has none (older versions wrote empty locks). A live A5N run keeps
# its lock however old: a suspend, or a raw file copy stuck for an hour per
# project, stops the touches and not the run, and a waiting job that took
# such a lock stashed the running unit as a killed one's and ran next to it.
lock_is_stale() {
  if [[ "$LOCK_PID" == <-> ]]; then
    if [ "$LOCK_PID" = $$ ]; then
      LOCK_STALE_WHY="it holds this run's own pid, left by an earlier process"
      return 0
    fi
    if ! kill -0 "$LOCK_PID" 2>/dev/null; then
      LOCK_STALE_WHY="owner pid $LOCK_PID is dead"
      return 0
    fi
    lock_owner_is_a5n "$LOCK_PID" && return 1
  fi
  if [ "$LOCK_AGE" -gt "$LOCK_STALE" ]; then
    LOCK_STALE_WHY="not touched for ${LOCK_AGE}s, and pid ${LOCK_PID:-?} is no A5N run"
    return 0
  fi
  return 1
}

# One step. With noclobber, > opens the file with O_EXCL, so of two runs
# that create it in the same instant exactly one succeeds. It used to be a
# look first and a write after the trap setup, and two runs a timer started
# at the same boot could both pass the look. CLOBBER_EMPTY, off unless a
# .zshenv turns it on, lets > reuse an empty file, and a lock is empty for
# an instant after another run creates it. zsh before 5.9 has no such
# option, hence the quiet failure.
lock_create() {
  setopt localoptions noclobber
  unsetopt clobberempty 2>/dev/null
  { print -r -- $$ > "$LOCK" } 2>/dev/null
}

# Runs "$@" in a subshell that holds the lock guard. Removing a lock is a
# look, then a remove: two waiters that looked at a stale lock in the same
# instant both removed it, the second one the lock the first had just
# written, and both ran. So every remove happens under a second lock, one
# the kernel holds, after a look taken under it too. The kernel drops it
# when its process exits, so it can never go stale itself. A subshell holds
# it, on a file nothing else opens, because closing any descriptor of the
# file drops it as well. Without zsh/system or a writable file there is no
# guard, and the remove goes on the way it did before the guard existed:
# a stale lock that stays for good would swallow every later run.
# 1 when another process held the guard for ten seconds.
lock_guarded() {
  touch "$LOCK_GUARD" 2>/dev/null
  (
    zmodload -F zsh/system b:zsystem 2>/dev/null && zsystem flock -t 10 "$LOCK_GUARD" 2>/dev/null
    case $? in
      0) ;;
      2) exit 1 ;;
      *) log "WARNING: cannot take the lock guard $LOCK_GUARD (it needs zsh/system and a writable file), going on without it" ;;
    esac
    "$@"
  )
}

lock_takeover() {  # under the guard: 0 when this run's lock replaced a stale one
  lock_read
  lock_is_stale || return 1
  rm -f "$LOCK"
  lock_create || return 1
  log "WARNING: stale lock found ($LOCK_STALE_WHY), removing and continuing"
  return 0
}

# One attempt. 0 taken; 1 another run holds the lock (LOCK_PID, LOCK_AGE).
lock_take() {
  if lock_create; then
    LOCK_TAKEN=1
    return 0
  fi
  lock_read
  # Gone between the two looks: its owner has just left.
  if [ ! -e "$LOCK" ] && lock_create; then
    LOCK_TAKEN=1
    return 0
  fi
  lock_is_stale || return 1
  if lock_guarded lock_takeover; then
    LOCK_TAKEN=1
    return 0
  fi
  lock_read
  return 1
}

# The owner's sign of life: after every unit, and all through the waits for
# the remote. -c, because a lock this run no longer has (taken over, removed
# by hand) must not come back as an empty file that nobody removes.
lock_touch() {
  touch -c "$LOCK" 2>/dev/null
}

# The lock, waited for while another run holds it: a look every LOCK_POLL
# seconds, at most LOCK_WAIT seconds. 0 taken; 1 still held when the wait
# ran out (LOCK_PID, LOCK_AGE). The driver sets its traps first, so a stop
# during the wait leaves as a stop.
lock_wait() {  # <job>: ingest, lint or digest
  local start=$SECONDS
  lock_take && return 0
  log "waiting for the local lock, held by pid ${LOCK_PID:-?} (${LOCK_AGE}s): a look every ${LOCK_POLL}s, at most ${LOCK_WAIT}s"
  # A run started by hand must not sit there in silence; only such a run
  # has a terminal.
  [ -t 2 ] && print -r -- "A5N $1: waiting for another A5N run (pid ${LOCK_PID:-?}) to finish, at most ${LOCK_WAIT}s; Ctrl-C stops this one" >&2
  while [ $(( SECONDS - start )) -lt "$LOCK_WAIT" ]; do
    sleep "$LOCK_POLL"
    if lock_take; then
      log "local lock taken after a $(( SECONDS - start ))s wait"
      return 0
    fi
  done
  [ -t 2 ] && print -r -- "A5N $1: another A5N run (pid ${LOCK_PID:-?}) still holds the lock after ${LOCK_WAIT}s, this run gives up" >&2
  return 1
}

lock_drop() {  # under the guard: the lock goes only while it holds this run's pid
  [ "$(cat "$LOCK" 2>/dev/null)" = $$ ] && rm -f "$LOCK"
  return 0
}

# EXIT trap. Only a lock this run took, and only while it is still this
# run's: a run stopped while it waited leaves the other run's lock alone,
# and so does a run whose lock was taken over or removed meanwhile. Under
# the guard, so a waiter looking at the lock cannot see it vanish between
# its look and its remove. A guard held for ten seconds by somebody else
# does not keep this run's lock behind.
lock_release() {
  [ -n "$LOCK_TAKEN" ] || return 0
  LOCK_TAKEN=""
  lock_guarded lock_drop || lock_drop
  return 0
}
