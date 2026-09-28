# Shared by the three run drivers (daily-ingest.sh, weekly-lint.sh,
# digest.sh): what they have in common that is not sync. Sourced, never
# executed. Before sourcing, a driver defines log() and notify_fail() and
# sets LOGDIR and LOG; recover_interrupted_unit runs with the vault as its
# working directory.

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
