# A5N sync: one vault kept in step across machines. Sourced by the three
# drivers, never executed. Off by default, and with [sync] enabled = no every
# function returns before running a single command, so a vault that does not
# sync behaves exactly as it did before this file existed.
#
# Contract with the driver: log() and notify_fail() are defined, VAULT,
# LOGDIR, LOG and LOCK are set, and the functions run with the vault as the
# working directory.
#
# Pages travel through a git remote. Raw transcripts travel with them or,
# when raw/ is kept out of git, through any storage rclone can reach
# (sync.raw_remote), every machine keeping a full copy. A ref on the remote,
# refs/a5n/lock, lets one machine at a time run model workers. The README
# section "Two machines, one vault" is the user's side of this file.
#
# SYNC_STATE after sync_begin: off (sync disabled); online; offline (the
# remote could not be reached: capture and local commits go on, layer 2
# does not); blocked (local commits conflict with the remote: a person has
# to look, layer 2 does not run).
#
# Every variable a colon follows is braced, ${var}:... . zsh reads $var:r
# as a modifier, and an unbraced "<commit>:refs/a5n/lock" lost its ":r" and
# became a refspec that matches nothing, so every lock push failed.

SYNC_STATE=off
SYNC_JOB=""
SYNC_REMOTE_BRANCH=0     # 1 once the remote branch is known to exist
SYNC_CONFLICTS=""        # paths of the last rebase conflict, for messages
SYNC_REQUEUE=0           # 1 when the queue must be rebuilt after a wait
SYNC_SKIP_REASON=""      # why layer 2 does not run, for the drivers
SYNC_HAVE_LOCK=""        # set while this run holds the remote lock
SYNC_LOCK_OID=""         # our lock commit: the lease for refresh and release
SYNC_LOCK_HOLDER=""      # the lock's message when someone else holds it
SYNC_LOCK_REFUSED=""     # the remote refused to create the lock ref

SYNC_MARKER="$LOGDIR/.sync-rebase"
SYNC_FAILING="$LOGDIR/.sync-failing-since"
SYNC_LOCK_REF="refs/a5n/lock"
SYNC_SEEN_REF="refs/a5n/seen-lock"

# The waits. The environment overrides exist for tests/sync-e2e.sh.
SYNC_WAIT="${A5N_SYNC_WAIT:-3600}"
SYNC_POLL="${A5N_SYNC_POLL:-300}"
SYNC_RETRY_DELAY="${A5N_SYNC_RETRY_DELAY:-20}"
SYNC_STALE=7200               # the local lock's staleness rule, on purpose
SYNC_GIT_TIMEOUT=120
SYNC_RCLONE_TIMEOUT=3600

sync_on() { [ "${A5N_SYNC_ENABLED:-no}" = yes ]; }

# --- helpers -------------------------------------------------------------------

# Network commands run under a wall clock. Without one a hung push keeps the
# driver alive, so the pid in the local lock stays alive too, and every
# later run skips in silence behind it. macOS has no timeout(1): this is the
# TERM-trapped watchdog the unit worker uses, whose sleep dies with it so
# nothing holds the caller's stdout open.
sync_bounded() {  # <seconds> <command...>
  local secs="$1" pid watchdog rc
  shift
  "$@" < /dev/null &
  pid=$!
  (
    trap 'kill $! 2>/dev/null; exit 0' TERM
    sleep "$secs" & wait $!
    kill -TERM "$pid" 2>/dev/null
  ) > /dev/null 2>&1 &
  watchdog=$!
  wait "$pid"
  rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return $rc
}

# A network git command: bounded, and never waiting for a password nobody is
# there to type.
sync_git() {
  sync_bounded "$SYNC_GIT_TIMEOUT" env GIT_TERMINAL_PROMPT=0 git "$@"
}

sync_ok() {
  rm -f "$SYNC_FAILING"
}

# The day rule. One failed sync is weather: a train without Wi-Fi, a timer
# that fired before login unlocked the keyring. A sync failing for more than
# a day is a revoked token or a moved remote, and layer 2 has stood still
# all that time. The clock starts at the first failure after a success, not
# at the last success: a desktop that is off over the weekend must not alert
# every Monday.
sync_failed() {  # <reason>
  local now first
  now="$(date +%s)"
  first="$(cat "$SYNC_FAILING" 2>/dev/null)"
  if [[ "$first" != <-> ]]; then
    print -r -- "$now" > "$SYNC_FAILING"
    return 0
  fi
  if [ $(( now - first )) -gt 86400 ]; then
    notify_fail "sync has been failing for $(( (now - first) / 3600 )) hours, layer 2 is not running; last error: $1"
  fi
  return 0
}

sync_in_progress() {  # prints the git operation left unfinished, if any
  local p
  for p in rebase-merge rebase-apply; do
    if [ -d "$(git rev-parse --git-path "$p")" ]; then
      print -r -- rebase
      return 0
    fi
  done
  for p in MERGE_HEAD:merge CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert; do
    if [ -e "$(git rev-parse --git-path "${p%%:*}")" ]; then
      print -r -- "${p#*:}"
      return 0
    fi
  done
  return 1
}

# Every namespace of the vault by the lint's rule (a root directory holding
# sources/), plus every configured project, so a project that has not
# written a page yet still gets its raw files copied.
sync_namespaces() {
  local d
  {
    for d in ${=A5N_PROJECT_NAMES}; do print -r -- "$d"; done
    for d in */(N); do [ -d "${d}sources" ] && print -r -- "${d%/}"; done
  } | sort -u
}

sync_ahead() {  # local commits the remote branch does not have
  if [ "$SYNC_REMOTE_BRANCH" = 1 ]; then
    git rev-list --count "$A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH..HEAD"
  else
    git rev-list --count HEAD 2>/dev/null || print 0
  fi
}

# A rebase A5N starts is announced on disk first, so a later run that finds
# a rebase in progress can tell its own interrupted one (safe to abort) from
# one the user is in the middle of (never touched). 0 done; 1 conflict,
# aborted, the paths in SYNC_CONFLICTS.
sync_rebase_onto() {
  : > "$SYNC_MARKER"
  if git rebase "$A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH" >> "$LOG" 2>&1; then
    rm -f "$SYNC_MARKER"
    return 0
  fi
  SYNC_CONFLICTS="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
  SYNC_CONFLICTS="${SYNC_CONFLICTS% }"
  SYNC_CONFLICTS="${SYNC_CONFLICTS:-see the log}"
  [ -n "$(sync_in_progress)" ] && git rebase --abort >> "$LOG" 2>&1
  rm -f "$SYNC_MARKER"
  return 1
}

# git pull --rebase in two halves, so "cannot reach the remote" and "cannot
# rebase onto it" stay different outcomes. Three attempts: launchd starts a
# job missed during sleep right at wake, before the network is back. 0
# reachable (SYNC_REMOTE_BRANCH says whether the branch exists yet), 1 not.
sync_fetch() {
  local try
  for try in 1 2 3; do
    if sync_git fetch --no-tags "$A5N_SYNC_REMOTE" \
        "+refs/heads/${A5N_SYNC_BRANCH}:refs/remotes/${A5N_SYNC_REMOTE}/${A5N_SYNC_BRANCH}" >> "$LOG" 2>&1; then
      SYNC_REMOTE_BRANCH=1
      return 0
    fi
    # A fresh remote has no branch yet: reachable, the first push creates it.
    sync_git ls-remote --exit-code --heads "$A5N_SYNC_REMOTE" "$A5N_SYNC_BRANCH" > /dev/null 2>> "$LOG"
    if [ $? -eq 2 ]; then
      SYNC_REMOTE_BRANCH=0
      return 0
    fi
    [ "$try" -lt 3 ] && sleep "$SYNC_RETRY_DELAY"
  done
  return 1
}

# rclone copy --immutable never deletes and never overwrites: a raw file is
# written once under a unique name, so there is nothing to reconcile.
# .gitkeep placeholders stay out, because to --immutable an mtime change on
# one is a modification (exit code 6 on a real vault). 0 every namespace
# copied; 1 at least one failed, and the user was told.
sync_raw() {  # <down|up>
  [ -n "${A5N_SYNC_RAW_REMOTE:-}" ] || return 0
  local ns src dst rc failed=""
  for ns in $(sync_namespaces); do
    if [ "$1" = down ]; then
      src="$A5N_SYNC_RAW_REMOTE/$ns/raw"
      dst="$VAULT/$ns/raw"
    else
      [ -d "$VAULT/$ns/raw" ] || continue
      src="$VAULT/$ns/raw"
      dst="$A5N_SYNC_RAW_REMOTE/$ns/raw"
    fi
    sync_bounded "$SYNC_RCLONE_TIMEOUT" rclone copy --immutable --exclude .gitkeep "$src" "$dst" >> "$LOG" 2>&1
    rc=$?
    # 3 is rclone's "directory not found": nothing uploaded for it yet.
    [ "$1" = down ] && [ "$rc" -eq 3 ] && rc=0
    [ "$rc" -eq 0 ] || failed="$failed $ns"
  done
  if [ -n "$failed" ]; then
    notify_fail "raw file copy (${1}load) failed for:$failed; the run goes on, the next run tries again"
    return 1
  fi
  log "sync: raw files ${1}loaded"
  return 0
}

# The push rules. 0 pushed, or nothing to push; 1 the remote cannot be
# reached; 2 a rebase onto the remote conflicted (aborted, local commits
# untouched); 3 refused twice.
sync_push() {
  if [ "$(sync_ahead)" -eq 0 ]; then
    sync_ok
    return 0
  fi
  if sync_git push "$A5N_SYNC_REMOTE" "HEAD:refs/heads/$A5N_SYNC_BRANCH" >> "$LOG" 2>&1; then
    sync_pushed
    return 0
  fi
  if ! sync_fetch; then
    sync_failed "push: $A5N_SYNC_REMOTE unreachable"
    return 1
  fi
  if [ "$SYNC_REMOTE_BRANCH" = 1 ] && ! sync_rebase_onto; then
    sync_failed "push: rebase conflict in $SYNC_CONFLICTS"
    return 2
  fi
  if sync_git push "$A5N_SYNC_REMOTE" "HEAD:refs/heads/$A5N_SYNC_BRANCH" >> "$LOG" 2>&1; then
    sync_pushed
    return 0
  fi
  sync_failed "push refused twice"
  return 3
}

sync_pushed() {
  # The remote branch is HEAD now. Moving the tracking ref by hand keeps the
  # next ahead count right without another fetch.
  git update-ref "refs/remotes/$A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH" HEAD
  SYNC_REMOTE_BRANCH=1
  sync_ok
  log "sync: pushed"
}

# --- used by the drivers --------------------------------------------------------

# Before anything writes. A5N's own rebase that a killed run left behind is
# aborted; a git operation the user left unfinished, or another branch
# checked out, stops the run untouched, because committing into either would
# be worse than a skipped day. 0 go on, 1 stop (the user was told).
sync_recover() {
  sync_on || return 0
  local op head
  if [ -e "$SYNC_MARKER" ]; then
    if [ "$(sync_in_progress)" = rebase ]; then
      git rebase --abort >> "$LOG" 2>&1
      log "WARNING: sync: aborted a rebase an interrupted run left behind"
    fi
    rm -f "$SYNC_MARKER"
  fi
  op="$(sync_in_progress)"
  if [ -n "$op" ]; then
    notify_fail "the vault has a $op in progress, run skipped; finish or abort it by hand"
    return 1
  fi
  head="$(git symbolic-ref -q --short HEAD)"
  if [ "$head" != "$A5N_SYNC_BRANCH" ]; then
    notify_fail "the vault is on '${head:-a detached HEAD}', sync expects '$A5N_SYNC_BRANCH', run skipped"
    return 1
  fi
  return 0
}

# Pull, then the raw download, then one try at the remote lock. Sets
# SYNC_STATE.
sync_begin() {  # <job> <raw download: yes|no> <remote lock: yes|no>
  sync_on || { SYNC_STATE=off; return 0; }
  SYNC_JOB="$1"
  if ! sync_fetch; then
    SYNC_STATE=offline
    log "WARNING: sync: $A5N_SYNC_REMOTE unreachable, working offline: layer 2 skipped, commits wait for the next run"
    sync_failed "$A5N_SYNC_REMOTE unreachable"
    return 0
  fi
  if [ "$SYNC_REMOTE_BRANCH" = 1 ] && ! sync_rebase_onto; then
    SYNC_STATE=blocked
    sync_failed "rebase conflict in $SYNC_CONFLICTS"
    notify_fail "local commits conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH ($SYNC_CONFLICTS), layer 2 skipped; resolve by hand: git pull --rebase in the vault"
    return 0
  fi
  SYNC_STATE=online
  log "sync: in step with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH"
  [ "$(sync_ahead)" -eq 0 ] && sync_ok
  [ "$2" = yes ] && sync_raw down
  return 0
}

# After layer 1, lock or no lock: raw files first, then the commits, so a
# page never reaches the other machine before the raw file it cites. These
# commits are manual edits and skip lines, not units: a conflict cannot drop
# them, it stops layer 2 until a person looks.
sync_publish() {
  sync_on || return 0
  [ "$SYNC_STATE" = online ] || return 0
  sync_raw up
  sync_push
  case $? in
    0) ;;
    2)
      SYNC_STATE=blocked
      notify_fail "local commits conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH ($SYNC_CONFLICTS), layer 2 skipped; resolve by hand: git pull --rebase in the vault" ;;
    *)
      SYNC_STATE=offline
      log "WARNING: sync: push failed, commits stay local, layer 2 skipped" ;;
  esac
  return 0
}

# Whether layer 2 may start. 0 yes (rebuild the queue first when
# SYNC_REQUEUE=1); 1 no, the reason in SYNC_SKIP_REASON.
sync_ready_for_workers() {
  SYNC_REQUEUE=0
  SYNC_SKIP_REASON=""
  sync_on || return 0
  case "$SYNC_STATE" in
    offline)
      SYNC_SKIP_REASON="$A5N_SYNC_REMOTE unreachable"
      log "sync: offline, layer 2 skipped, the queue waits for the next run"
      return 1 ;;
    blocked)
      SYNC_SKIP_REASON="local commits conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH"
      log "sync: blocked by a conflict, layer 2 skipped"
      return 1 ;;
  esac
  return 0
}

# After a unit's commit. 0 go on; 1 stop layer 2 (the commit stays local and
# the next run pushes it: a valid unit is never thrown away for a network
# problem); 2 the unit was dropped after a conflict and stays queued, layer
# 2 may go on.
sync_push_unit() {  # <commit the unit started from>
  sync_on || return 0
  [ "$SYNC_STATE" = online ] || return 0
  sync_push
  case $? in
    0) return 0 ;;
    2)
      git reset --hard --quiet "$1" >> "$LOG" 2>&1
      git clean -fd --quiet >> "$LOG" 2>&1
      log "sync: unit commit dropped after a rebase conflict ($SYNC_CONFLICTS), the unit stays queued"
      if [ "$SYNC_REMOTE_BRANCH" = 1 ] && ! sync_rebase_onto; then
        SYNC_STATE=blocked
        notify_fail "the vault cannot follow $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH ($SYNC_CONFLICTS), layer 2 stopped; resolve by hand"
        return 1
      fi
      return 2 ;;
    1)
      SYNC_STATE=offline
      log "WARNING: sync: $A5N_SYNC_REMOTE unreachable mid run, the commit stays local, layer 2 stops"
      return 1 ;;
    *)
      SYNC_STATE=offline
      log "WARNING: sync: push refused twice, the commit stays local, layer 2 stops"
      return 1 ;;
  esac
}
