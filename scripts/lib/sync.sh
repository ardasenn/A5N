# A5N sync: one vault kept in step across machines. Sourced by the three
# drivers, never executed. Off by default, and with [sync] enabled = no every
# function returns before running a single command, so a vault that does not
# sync behaves exactly as it did before this file existed.
#
# Contract with the driver: log() and notify_fail() are defined, VAULT,
# LOGDIR, LOG and LOCK are set, lib/common.sh is sourced (sync_begin and
# sync_ready_for_workers commit hand edits through it), and the functions
# run with the vault as the working directory.
#
# Pages travel through a git remote. Raw transcripts travel with them or,
# when raw/ is kept out of git, through any storage rclone can reach
# (sync.raw_remote), every machine keeping a full copy. A ref on the remote,
# refs/a5n/lock, lets one machine at a time run model workers. The README
# section "Two machines, one vault" is the user's side of this file.
#
# SYNC_STATE after sync_begin: off (sync disabled); online; offline (the
# remote could not be reached, not even within sync.offline_after: capture
# and local commits go on, layer 2 does not); blocked (local commits
# conflict with the remote: a person has to look, layer 2 does not run).
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

# The waits. The environment overrides exist for tests/sync-e2e.sh. How long
# the start of a run waits for an unreachable remote is a setting instead,
# sync.offline_after: it depends on the machine (see sync_reach).
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
  # KILL is the last word, for the sleep and for the command: a process
  # started while a signal trap runs inherits that signal blocked, and the
  # lock release runs from the drivers' TERM trap. With TERM alone the
  # sleep outlived the run and systemctl stop waited 90 s for it, then
  # marked the stop failed.
  (
    trap 'kill -KILL $! 2>/dev/null; exit 0' TERM
    sleep "$secs" & wait $!
    kill -TERM "$pid" 2>/dev/null || exit 0
    sleep 5 & wait $!
    kill -KILL "$pid" 2>/dev/null
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
# rebase onto it" stay different outcomes. One attempt: 0 reachable
# (SYNC_REMOTE_BRANCH says whether the branch exists yet), 1 not.
sync_fetch_once() {
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
  return 1
}

# Three attempts: launchd starts a job missed during sleep right at wake,
# before the network is back. 0 reachable, 1 not.
sync_fetch() {
  local try
  for try in 1 2 3; do
    sync_fetch_once && return 0
    [ "$try" -lt 3 ] && sleep "$SYNC_RETRY_DELAY"
  done
  return 1
}

# Nobody logged in on this machine. With lingering on, systemd runs user
# timers without a session, so a run missed while the machine was off
# starts at boot, before anyone logs in, and a git credential kept in the
# desktop keyring (gh keeps its token there) stays locked until the login.
# loginctl calls such a user "lingering". macOS starts agents inside the
# login session and has no loginctl: there, and whenever loginctl gives no
# answer, somebody counts as logged in. The timeout: a question to logind
# must never hold the run, and its lock, hostage.
sync_no_login() {
  command -v loginctl > /dev/null 2>&1 || return 1
  [ "$(timeout 10 loginctl show-user "$(id -u)" -p State --value 2>/dev/null)" = lingering ]
}

# The start of a run only. A remote the three quick attempts could not reach
# gets up to sync.offline_after seconds, counted from the first attempt,
# before the run works offline. A timer with Persistent=true starts a run
# the machine was off for at boot, when the network may not be up yet and,
# with lingering on, nobody has logged in yet. Such a run used to go offline
# every time, and an offline lint or digest waits a week or a month for its
# next slot. While nobody is logged in the loop only watches for the login:
# every fetch would ask the credential helper for a locked keyring, and gh
# waits up to 60 s for it each time. When the time is up, one last attempt
# anyway, for a credential that needs no login. The local lock is touched
# every round, so a long wait never looks stale. 0 reachable, 1 not.
sync_reach() {
  local start=$SECONDS said=""
  sync_fetch && return 0
  while [ $(( SECONDS - start )) -lt "$A5N_SYNC_OFFLINE_AFTER" ]; do
    sleep "$SYNC_RETRY_DELAY"
    lock_touch
    if [ $(( SECONDS - start )) -lt "$A5N_SYNC_OFFLINE_AFTER" ] && sync_no_login; then
      [ "$said" = login ] || log "sync: $A5N_SYNC_REMOTE unreachable and nobody has logged in yet, waiting for a login (at most ${A5N_SYNC_OFFLINE_AFTER}s)"
      said=login
      continue
    fi
    [ -n "$said" ] || log "sync: $A5N_SYNC_REMOTE unreachable, trying again every ${SYNC_RETRY_DELAY}s (at most ${A5N_SYNC_OFFLINE_AFTER}s)"
    said=retry
    if sync_fetch_once; then
      log "sync: $A5N_SYNC_REMOTE reachable after $(( SECONDS - start ))s"
      return 0
    fi
  done
  return 1
}

# rclone copy --immutable never deletes and never overwrites: a raw file is
# written once under a unique name, so there is nothing to reconcile.
# Dotfiles stay out: the .gitkeep placeholders, and the .DS_Store Finder
# drops into any folder it shows. Both get rewritten, and to --immutable a
# rewritten file is a modified one (exit code 6 on a real vault), an alarm
# that would then fire on every run. A raw file is never a dotfile. 0 every
# namespace copied; 1 at least one failed, and the user was told.
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
    sync_bounded "$SYNC_RCLONE_TIMEOUT" rclone copy --immutable --exclude '.*' "$src" "$dst" >> "$LOG" 2>&1
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
  if [ -e "$SYNC_MARKER" ]; then
    if [ "$(sync_in_progress)" = rebase ]; then
      git rebase --abort >> "$LOG" 2>&1
      log "WARNING: sync: aborted a rebase an interrupted run left behind"
    fi
    rm -f "$SYNC_MARKER"
  fi
  sync_vault_ok
}

# The user's side of sync_recover, asked again after the waits for the
# remote and for its lock. 0 the vault is on the sync branch with no git
# operation in progress; 1 not (the user was told what the stop skips, the
# whole run unless the caller says otherwise).
sync_vault_ok() {  # [what the stop skips]
  local op head skipped="${1:-run}"
  op="$(sync_in_progress)"
  if [ -n "$op" ]; then
    notify_fail "the vault has a $op in progress, $skipped skipped; finish or abort it by hand"
    return 1
  fi
  head="$(git symbolic-ref -q --short HEAD)"
  if [ "$head" != "$A5N_SYNC_BRANCH" ]; then
    notify_fail "the vault is on '${head:-a detached HEAD}', sync expects '$A5N_SYNC_BRANCH', $skipped skipped"
    return 1
  fi
  return 0
}

# Pull (waiting for a remote that is out of reach, see sync_reach), then the
# raw download, then one try at the remote lock. Sets SYNC_STATE. 0 go on;
# 1 stop, the vault changed under the wait (the user was told).
sync_begin() {  # <job> <raw download: yes|no> <remote lock: yes|no>
  sync_on || { SYNC_STATE=off; return 0; }
  SYNC_JOB="$1"
  local unreachable=""
  sync_reach || unreachable=1
  # The driver checked the vault and committed hand edits before the wait,
  # and the wait can end just as somebody logs in and starts working. Found
  # in review: a hand edit made git refuse the rebase below, a conflict that
  # was not there, and layer 2 skipped; a rebase started by hand was aborted
  # by A5N's own, resolution and all; another branch checked out meanwhile
  # was rebased, processed and pushed to the sync branch. So once more: a
  # git operation in progress or another branch stops the run untouched,
  # and hand edits get a commit of their own.
  sync_vault_ok || return 1
  commit_manual_changes "$1"
  if [ -n "$unreachable" ]; then
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
  [ "$3" = yes ] && [ "$A5N_SYNC_LOCK" = yes ] && sync_lock_take
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
# SYNC_REQUEUE=1); 1 no, the reason in SYNC_SKIP_REASON; 2 stop, the vault
# changed under the wait for the remote lock (the user was told).
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
  [ "$A5N_SYNC_LOCK" = yes ] || return 0
  [ -n "$SYNC_HAVE_LOCK" ] && return 0
  local waited=0 skipped=run
  # The ingest has captured and pushed by now: a stop skips its workers only.
  [ "$SYNC_JOB" = ingest ] && skipped="layer 2"
  while [ -z "$SYNC_LOCK_REFUSED" ] && [ "$waited" -lt "$SYNC_WAIT" ]; do
    [ "$waited" -eq 0 ] && log "sync: waiting for the remote lock (every ${SYNC_POLL}s, at most ${SYNC_WAIT}s): $SYNC_LOCK_HOLDER"
    sleep "$SYNC_POLL"
    waited=$(( waited + SYNC_POLL ))
    lock_touch
    sync_lock_take || continue
    # An hour is time enough for somebody to start working in the vault, so
    # sync_begin's questions once more: a git operation in progress or
    # another branch stops the run untouched, hand edits get a commit of
    # their own. Without them, seen in tests/sync-e2e.sh: a hand edit made
    # git refuse the rebase below, a conflict that was not there; a rebase
    # started by hand was aborted by A5N's own; another branch was rebased,
    # processed and pushed to the sync branch. The hand edits go out with
    # the next push: the first unit's, or the next run's.
    sync_vault_ok "$skipped" || return 2
    commit_manual_changes "$SYNC_JOB"
    # The other machine may have processed units while this one waited.
    if ! sync_fetch; then
      SYNC_STATE=offline
      SYNC_SKIP_REASON="$A5N_SYNC_REMOTE unreachable"
      log "sync: the remote went away after the wait, layer 2 skipped"
      return 1
    fi
    if [ "$SYNC_REMOTE_BRANCH" = 1 ] && ! sync_rebase_onto; then
      SYNC_STATE=blocked
      SYNC_SKIP_REASON="local commits conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH"
      notify_fail "local commits conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH ($SYNC_CONFLICTS), layer 2 skipped; resolve by hand: git pull --rebase in the vault"
      return 1
    fi
    SYNC_REQUEUE=1
    return 0
  done
  if [ -n "$SYNC_LOCK_REFUSED" ]; then
    SYNC_SKIP_REASON="$A5N_SYNC_REMOTE refuses the lock ref"
  else
    SYNC_SKIP_REASON="the remote lock stayed busy ($SYNC_LOCK_HOLDER)"
  fi
  log "sync: layer 2 skipped, $SYNC_SKIP_REASON"
  return 1
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

# --- the remote lock -------------------------------------------------------------
# refs/a5n/lock on the sync remote. It points at a commit with an empty tree
# and no parent whose message names the owner; its age is the commit's
# committer time. The server compares the lease and writes in one step, so
# of two machines racing for it exactly one wins.

sync_lock_commit() {  # prints a fresh lock commit for this run
  local tree
  tree="$(git mktree < /dev/null)" || return 1
  git commit-tree "$tree" -m "a5n lock: host=${HOST:-$(hostname)} pid=$$ job=$SYNC_JOB at=$(date '+%FT%T%z')"
}

sync_lock_push() {  # <expected commit, empty: must not exist> <new commit, empty: delete>
  sync_git push --force-with-lease="${SYNC_LOCK_REF}:${1}" "$A5N_SYNC_REMOTE" "${2}:${SYNC_LOCK_REF}" >> "$LOG" 2>&1
}

sync_lock_remote() {  # prints the lock's commit, empty when free; 1 unreachable
  local out
  out="$(sync_git ls-remote "$A5N_SYNC_REMOTE" "$SYNC_LOCK_REF" 2>> "$LOG")" || return 1
  print -r -- "${out%%[[:space:]]*}"
}

# One try. 0 taken (SYNC_LOCK_OID is ours); 1 not (SYNC_LOCK_HOLDER says who
# has it).
sync_lock_take() {
  [ -n "$SYNC_LOCK_REFUSED" ] && return 1
  local new cur info ct subject host="" pid="" age tries=0
  new="$(sync_lock_commit)" || { log "sync: could not build a lock commit"; return 1; }
  while :; do
    if sync_lock_push "" "$new"; then
      SYNC_HAVE_LOCK=1
      SYNC_LOCK_OID="$new"
      log "sync: remote lock taken"
      return 0
    fi
    cur="$(sync_lock_remote)" || { log "sync: remote unreachable while taking the lock"; return 1; }
    if [ -z "$cur" ]; then
      # Refused while nothing holds it: once can be a lock released in
      # between, twice is a remote that does not take custom refs.
      tries=$(( tries + 1 ))
      if [ "$tries" -lt 2 ]; then
        sleep 1
        continue
      fi
      SYNC_LOCK_REFUSED=1
      notify_fail "$A5N_SYNC_REMOTE refused to create $SYNC_LOCK_REF although no lock exists; the remote must accept custom refs for layer 2 to run"
      return 1
    fi
    sync_git fetch --no-tags "$A5N_SYNC_REMOTE" "+${SYNC_LOCK_REF}:${SYNC_SEEN_REF}" >> "$LOG" 2>&1 || return 1
    cur="$(git rev-parse "$SYNC_SEEN_REF")"
    info="$(git log -1 --format='%ct %s' "$SYNC_SEEN_REF")"
    ct="${info%% *}"
    subject="${info#* }"
    [[ "$subject" == *host=* ]] && host="${${subject#*host=}%% *}"
    [[ "$subject" == *pid=* ]] && pid="${${subject#*pid=}%% *}"
    [[ "$pid" == <-> ]] || pid=""
    [[ "$ct" == <-> ]] || ct="$(date +%s)"
    age=$(( $(date +%s) - ct ))
    SYNC_LOCK_HOLDER="$subject, ${age}s old"
    # Stale: older than the local lock's two hours, or this host's own lock
    # whose pid is gone (the local lock's dead owner rule, so a crash here
    # does not make this machine's next run wait two hours).
    if [ "$age" -gt "$SYNC_STALE" ] || \
       { [ "$host" = "${HOST:-$(hostname)}" ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; }; then
      if sync_lock_push "$cur" "$new"; then
        SYNC_HAVE_LOCK=1
        SYNC_LOCK_OID="$new"
        log "WARNING: sync: took over a stale remote lock ($SYNC_LOCK_HOLDER)"
        return 0
      fi
      return 1
    fi
    log "sync: remote lock held ($SYNC_LOCK_HOLDER)"
    return 1
  done
}

# After every unit, the remote twin of touching the local lock: without it a
# normal run longer than two hours would look stale to the other machine.
# 0 go on; 1 the lock is gone (or the remote is), stop layer 2.
sync_lock_refresh() {
  sync_on || return 0
  [ -n "$SYNC_LOCK_OID" ] || return 0
  local new cur
  new="$(sync_lock_commit)" || return 0
  if sync_lock_push "$SYNC_LOCK_OID" "$new"; then
    SYNC_LOCK_OID="$new"
    return 0
  fi
  if ! cur="$(sync_lock_remote)"; then
    SYNC_STATE=offline
    log "WARNING: sync: remote unreachable while refreshing the lock, layer 2 stops"
    return 1
  fi
  if [ "$cur" = "$SYNC_LOCK_OID" ]; then
    log "WARNING: sync: lock refresh refused but the lock is still ours, going on"
    return 0
  fi
  SYNC_HAVE_LOCK=""
  SYNC_LOCK_OID=""
  notify_fail "the remote lock was taken over by another machine mid run, layer 2 stopped"
  return 1
}

# EXIT trap. The lease is our own commit, so a run that lost its lock can
# never delete the new owner's.
sync_lock_release() {
  sync_on || return 0
  [ -n "$SYNC_LOCK_OID" ] || return 0
  if sync_lock_push "$SYNC_LOCK_OID" ""; then
    log "sync: remote lock released"
  else
    log "WARNING: sync: could not release the remote lock; it goes stale in two hours, at once for this machine's next run"
  fi
  SYNC_HAVE_LOCK=""
  SYNC_LOCK_OID=""
}
