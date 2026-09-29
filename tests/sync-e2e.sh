#!/bin/zsh
# End to end tests for A5N's [sync] section and the fixes that shipped with
# it: the interrupted unit stash, .gitkeep placeholders, schedule "off" and
# desktop notifications, the macOS one through stand ins. The local lock
# the three jobs share is tested here too (the t_local_* scenarios).
#
# Everything happens inside one temporary directory, whose name contains
# spaces on purpose so every path the drivers handle is exercised quoted. A
# bare repository plays the git remote, an rclone "local" remote plays the
# cloud storage, and each machine gets its own config.ini, vault and
# transcript folder. HOME and XDG_CONFIG_HOME point inside the directory and
# small shims stand in for systemctl, launchctl, loginctl and notify-send, so
# no real vault, timer, remote or desktop notification is ever touched. The
# model is replaced by tests/fake-runner.sh. Asked for the login state,
# the loginctl shim reads it from a file each world owns (active when the
# file is missing), so a scenario can play a boot nobody has logged in to.
#
# Usage:
#   zsh tests/sync-e2e.sh                        every scenario
#   zsh tests/sync-e2e.sh offline lock_race      only these
#   A5N_BASELINE_REF=<commit> zsh tests/sync-e2e.sh sync_off_identical
#   A5N_KEEP_TEST_DIR=1 zsh tests/sync-e2e.sh    keep the directory
#
# Linux only for now: the scheduler scenario drives setup.sh's systemd
# branch, and the fixtures use GNU date, sed and touch. Needs git, rclone and
# python3.
set -u

REPO="${0:A:h:h}"
TODAY="$(date +%F)"
REAL_GIT="$(command -v git)"
REAL_RCLONE="$(command -v rclone)"

if [ "$(uname)" != "Linux" ]; then
  print -r -- "tests/sync-e2e.sh runs on Linux only for now" >&2
  exit 2
fi
if [ -z "$REAL_RCLONE" ]; then
  print -r -- "rclone is required: a local rclone remote plays the cloud storage" >&2
  exit 2
fi

TOP="$(mktemp -d "${TMPDIR:-/tmp}/a5n sync e2e.XXXXXX")"
PASSED=0; FAILED=0; FAILURES=(); CURRENT=""

# --- isolation ---------------------------------------------------------------
export HOME="$TOP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="A5N Test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="A5N Test" GIT_COMMITTER_EMAIL="test@example.invalid"
export RCLONE_CONFIG="$TOP/rclone.conf"
export A5N_TEST_REAL_GIT="$REAL_GIT" A5N_TEST_REAL_RCLONE="$REAL_RCLONE"
export A5N_TEST_CALLS="$TOP/calls"
export A5N_BACKFILL=no
export A5N_SYNC_RETRY_DELAY=0 A5N_SYNC_POLL=1 A5N_SYNC_WAIT=3
# A scenario that meets a held local lock by mistake waits seconds, not
# the two hours a real run waits.
export A5N_LOCK_POLL=1 A5N_LOCK_WAIT=30
export A5N_PROMPT_FILE="$TOP/unit-prompt.md" A5N_LINT_PROMPT_FILE="$TOP/lint-prompt.md"
unset A5N_NO_NOTIFY A5N_CONFIG A5N_MAX_UNITS A5N_UNIT_TIMEOUT A5N_LINT_PROJECTS A5N_OSASCRIPT
unset FAKE_RUNNER_HOOK FAKE_RUNNER_SLEEP FAKE_RUNNER_PIDFILE FAKE_RUNNER_SHARED
mkdir -p "$XDG_CONFIG_HOME" "$TOP/bin" "$A5N_TEST_CALLS"
print -r -- "[fakedrive]
type = local" > "$RCLONE_CONFIG"

# The drivers fill these templates like the real prompts; they carry
# key=value lines only, which is all the fake runner reads.
print -r -- "A5N-TEST-UNIT
project=__PROJECT__
session=__SESSION_ID__
raw=__RAW__
date=__DATE__" > "$A5N_PROMPT_FILE"
print -r -- "A5N-TEST-LINT
project=__PROJECT__
date=__DATE__" > "$A5N_LINT_PROMPT_FILE"

# --- shims -------------------------------------------------------------------
# Each records its calls in $A5N_TEST_CALLS/<name>.log. git and rclone then
# run the real binary; git records only the commands that use the network.
shim() {  # <name> <shell body>
  print -r -- "#!/bin/sh
$2" > "$TOP/bin/$1"
  chmod +x "$TOP/bin/$1"
}
shim notify-send 'printf "%s\n" "$*" >> "$A5N_TEST_CALLS/notify.log"'
shim systemctl 'printf "%s\n" "$*" >> "$A5N_TEST_CALLS/systemctl.log"'
shim launchctl 'printf "%s\n" "$*" >> "$A5N_TEST_CALLS/launchctl.log"'
shim loginctl 'printf "%s\n" "$*" >> "$A5N_TEST_CALLS/loginctl.log"
case "$*" in
  *State*) cat "$A5N_TEST_LOGIN" 2>/dev/null || echo active ;;
  *) echo Linger=yes ;;
esac'
shim rclone 'printf "%s\n" "$*" >> "$A5N_TEST_CALLS/rclone.log"
exec "$A5N_TEST_REAL_RCLONE" "$@"'
shim git 'sub=""; skip=""
for a in "$@"; do
  if [ -n "$skip" ]; then skip=""; continue; fi
  case "$a" in -C|-c) skip=1 ;; -*) ;; *) sub="$a"; break ;; esac
done
case "$sub" in
  fetch|push|pull|ls-remote|clone) printf "%s\n" "$*" >> "$A5N_TEST_CALLS/git-net.log" ;;
esac
exec "$A5N_TEST_REAL_GIT" "$@"'
export PATH="$TOP/bin:$PATH"

# --- fixtures ----------------------------------------------------------------
# Session ids differ in their first eight characters, which is what page
# names and log lines use.
A1=a1000001-0000-4000-8000-000000000001
A2=a1000002-0000-4000-8000-000000000002
B1=b2000001-0000-4000-8000-000000000001
G1=c3000001-0000-4000-8000-000000000001
G2=c3000002-0000-4000-8000-000000000002
S1=d4000001-0000-4000-8000-000000000001
S2=d4000002-0000-4000-8000-000000000002

# --- worlds ------------------------------------------------------------------
# A world is one remote, one storage and up to two machines, m1 and m2.
world() {  # <name>
  W="$TOP/$1"
  mkdir -p "$W/calls" "$W/drive"
  export A5N_TEST_CALLS="$W/calls" A5N_TEST_LOGIN="$W/login-state"
  git init -q --bare -b main "$W/origin.git"
}

# machine_config <machine> <sync on|off> <lock yes|no> <project...>
# CFG_SCHEDULE replaces the [schedule] body, CFG_RAW_REMOTE sync.raw_remote
# (set it empty to keep raw files in git), CFG_OFFLINE_AFTER
# sync.offline_after (0 unless set: no wait, the start every scenario before
# the wait was written against).
machine_config() {
  local m="$1" sync="$2" lock="$3" enabled=no p
  shift 3
  [ "$sync" = on ] && enabled=yes
  mkdir -p "$W/$m/claude"
  {
    print -r -- "[vault]
path = $W/$m/vault
language = English
title = Test Vault

[agents]
claude_projects = $W/$m/claude
codex_sessions =

[runner]
engine = claude
bin = $REPO/tests/fake-runner.sh
model = fake

[schedule]
${CFG_SCHEDULE:-enabled = no}

[limits]
min_session_kb = 1
settle_hours = 0
unit_timeout = 60
max_units = 15

[sync]
enabled = $enabled
remote = origin
branch = main
raw_remote = ${CFG_RAW_REMOTE-fakedrive:$W/drive}
lock = $lock
offline_after = ${CFG_OFFLINE_AFTER:-0}
"
    for p in "$@"; do
      print -r -- "[project:$p]
match = $p
watermark = 2026-01-01
"
    done
  } > "$W/$m/config.ini"
}

a5n() {  # <machine> <script> [args...]: run an A5N script as that machine
  A5N_CONFIG="$W/$1/config.ini" zsh "$REPO/scripts/$2" "${@:3}"
}

machine_new() {  # <machine>: a new vault that pushes to the world's remote
  local v="$W/$1/vault"
  mkdir -p "$v"
  print -r -- ".a5n-logs/
**/raw/" > "$v/.gitignore"
  git -C "$v" init -q -b main
  git -C "$v" remote add origin "$W/origin.git"
  a5n "$1" setup.sh > "$W/$1/setup.out" 2>&1
}

machine_clone() {  # <machine>: a vault cloned from the world's remote
  git clone -q "$W/origin.git" "$W/$1/vault"
  a5n "$1" setup.sh > "$W/$1/setup.out" 2>&1
}

machine_local() {  # <machine>: setup.sh creates the repository, no remote
  a5n "$1" setup.sh > "$W/$1/setup.out" 2>&1
}

# session <machine> <project> <id> <date> [small]: a Claude Code transcript
# in the machine's transcript folder; "small" stays under min_session_kb.
session() {
  local dir="$W/$1/claude/-home-dev-$2" f i
  mkdir -p "$dir"
  f="$dir/$3.jsonl"
  print -r -- "{\"type\":\"user\",\"sessionId\":\"$3\",\"timestamp\":\"$4T09:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"first line of $3\"}}" > "$f"
  [ "${5:-}" = small ] && return 0
  for i in {1..20}; do
    print -r -- "{\"type\":\"assistant\",\"sessionId\":\"$3\",\"timestamp\":\"$4T09:30:00.000Z\",\"message\":{\"role\":\"assistant\",\"content\":\"step $i of $3, padding so the transcript passes min_session_kb\"}}" >> "$f"
  done
}

pages_for() {  # <vault> <session id>: source pages that cite the session
  grep -rlF "raw/sessions/$2.jsonl" "$1"/*/sources/sessions 2>/dev/null | wc -l | tr -d ' '
}
remote_pages_for() {  # <session id>: the same count on the remote's main
  git --git-dir="$W/origin.git" grep -lF "raw/sessions/$1.jsonl" main -- '*/sources/sessions/*' 2>/dev/null | wc -l | tr -d ' '
}
remote_file() {  # <path>: a file on the remote's main branch
  git --git-dir="$W/origin.git" show "main:$1" 2>/dev/null
}
remote_head() { git --git-dir="$W/origin.git" rev-parse -q --verify main 2>/dev/null; }
local_head() { git -C "$W/$1/vault" rev-parse HEAD 2>/dev/null; }
remote_lock() {  # the lock ref's commit, empty when there is none
  git --git-dir="$W/origin.git" rev-parse -q --verify refs/a5n/lock 2>/dev/null
}
vlog() {  # <machine> [ingest|lint|digest]: that machine's log of today
  local name="$TODAY.log"
  case "${2:-ingest}" in
    lint) name="lint-$TODAY.log" ;;
    digest) name="digest-$TODAY.log" ;;
  esac
  cat "$W/$1/vault/.a5n-logs/$name" 2>/dev/null
}
calls() { cat "$W/calls/$1.log" 2>/dev/null; }   # <shim name>
forget_calls() { rm -f "$W/calls/"*.log(N); }
overlap() {  # the first moment two fake workers ran in one vault at once
  awk '{ v = $0; sub(/^[a-z]+ [0-9]+ /, "", v) }
       $1 == "start" && ++n[v] > 1 { print "two workers at once in " v; exit }
       $1 == "end" { n[v]-- }' "$W/calls/workers.log" 2>/dev/null
}

fake_lock() {  # <message fields> <now|old>: another machine's lock
  local tree
  tree="$(git --git-dir="$W/origin.git" mktree < /dev/null)"
  if [ "$2" = old ]; then
    FAKE_LOCK="$(GIT_COMMITTER_DATE="$(( $(date +%s) - 10800 )) +0000" \
      git --git-dir="$W/origin.git" commit-tree "$tree" -m "a5n lock: $1 at=test")"
  else
    FAKE_LOCK="$(git --git-dir="$W/origin.git" commit-tree "$tree" -m "a5n lock: $1 at=test")"
  fi
  git --git-dir="$W/origin.git" update-ref refs/a5n/lock "$FAKE_LOCK"
}

session_left() {  # <session id>: processes still in that session
  ps -eo pid=,sid=,args= | awk -v s="$1" '$2 == s' 2>/dev/null
}

wait_for() {  # <description> <shell condition>, up to 30 seconds
  local i
  for i in {1..300}; do
    eval "$2" && return 0
    sleep 0.1
  done
  bad "timed out waiting: $1"
  return 1
}

# --- assertions --------------------------------------------------------------
ok()  { PASSED=$((PASSED+1)); print -r -- "  ok    $1"; }
bad() { FAILED=$((FAILED+1)); FAILURES+=("$CURRENT: $1"); print -r -- "  FAIL  $1"; }
check() {  # <description> <command...>: passes when the command succeeds
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
check_eq() {  # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
has() {  # <description> <text> <fixed string>
  if print -r -- "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (no '$3')"; fi
}
has_not() {  # <description> <text> <fixed string>
  if print -r -- "$2" | grep -qF -- "$3"; then bad "$1 (found '$3')"; else ok "$1"; fi
}

# --- scenarios ---------------------------------------------------------------

t_config_validation() {
  world config
  local cfg="$W/c.ini" out
  mini() {  # <extra ini text>: a minimal valid config plus the given text
    print -r -- "[vault]
path = $W/vault
[runner]
bin = /bin/true
[project:alpha]
match = alpha
watermark = 2026-01-01
$1" > "$cfg"
  }
  cfgout() { A5N_CONFIG="$cfg" python3 "$REPO/scripts/config.py" "$@" 2>&1; }

  mini ""
  out="$(cfgout --sh)"
  has "sync is off by default" "$out" "export A5N_SYNC_ENABLED='no'"
  has "remote defaults to origin" "$out" "export A5N_SYNC_REMOTE='origin'"
  has "branch defaults to main" "$out" "export A5N_SYNC_BRANCH='main'"
  has "raw_remote defaults to empty" "$out" "export A5N_SYNC_RAW_REMOTE=''"
  has "lock defaults to yes" "$out" "export A5N_SYNC_LOCK='yes'"
  has "the wait for the remote defaults to 15 minutes" "$out" "export A5N_SYNC_OFFLINE_AFTER='900'"
  has "check says sync is off" "$(cfgout --check)" "sync: off"

  mini "[sync]
enabled = YES
raw_remote = gdrive:vault/"
  out="$(cfgout --sh)"
  has "enabled is normalised" "$out" "export A5N_SYNC_ENABLED='yes'"
  has "a trailing slash is dropped" "$out" "export A5N_SYNC_RAW_REMOTE='gdrive:vault'"
  has "check prints the sync line" "$(cfgout --check)" \
    "sync: on, pages via origin/main, raw files via gdrive:vault, lock on"
  has "check prints the wait" "$(cfgout --check)" "lock on, offline after 900s"

  # The value reaches a shell test, where "15m" does not stop the run: the
  # wait is skipped, with nothing in the run's log.
  mini "[sync]
offline_after = 15m"
  has "offline_after must be whole seconds" "$(cfgout --check)" \
    "sync.offline_after is '15m'"

  mini "[sync]
offline_after = 0"
  has "offline_after may be 0" "$(cfgout --sh)" "export A5N_SYNC_OFFLINE_AFTER='0'"

  mini "[sync]
enabled = true"
  has "enabled must be yes or no" "$(cfgout --check)" \
    "sync.enabled is 'true', must be exactly 'yes' or 'no'"

  mini "[sync]
enabled = yes
lock = maybe"
  has "lock must be yes or no" "$(cfgout --check)" \
    "sync.lock is 'maybe', must be exactly 'yes' or 'no'"

  mini "[sync]
enabled = yes
remote ="
  has "a remote is required when sync is on" "$(cfgout --check)" \
    "sync.remote '' must be one word when sync is enabled"

  mini "[schedule]
lint = off
digest = OFF"
  out="$(cfgout --sh)"
  has "lint may be off" "$out" "export A5N_SCHEDULE_LINT='off'"
  has "off is normalised" "$out" "export A5N_SCHEDULE_DIGEST='off'"

  mini "[schedule]
lint = sometimes"
  has "a bad schedule still fails" "$(cfgout --check)" \
    "schedule.lint 'sometimes' is not valid"
}

t_setup_checks() {
  world setup
  local v="$W/m1/vault" units="$W/xdg/systemd/user" out attr
  local sched=$'enabled = yes\ningest = 09:07\nlint = off\ndigest = 1 09:37'
  export XDG_CONFIG_HOME="$W/xdg"

  # No remote: setup stops before any timer is touched.
  CFG_SCHEDULE="$sched" machine_config m1 on yes alpha
  mkdir -p "$v"
  print -r -- $'.a5n-logs/\n**/raw/' > "$v/.gitignore"
  git -C "$v" init -q -b main
  out="$(a5n m1 setup.sh 2>&1)"
  has "a missing remote stops setup" "$out" "sync is on but the vault has no git remote 'origin'"
  check_eq "no timer was touched" "" "$(calls systemctl)"

  # An rclone remote that does not exist.
  git -C "$v" remote add origin "$W/origin.git"
  CFG_RAW_REMOTE="nosuch:vault" CFG_SCHEDULE="$sched" machine_config m1 on yes alpha
  out="$(a5n m1 setup.sh 2>&1)"
  has "an unknown rclone remote stops setup" "$out" "rclone has no remote named 'nosuch:'"
  check_eq "still no timer touched" "" "$(calls systemctl)"

  # A lint timer from an earlier install, then a good config, twice.
  mkdir -p "$units"
  print -r -- "[Timer]" > "$units/a5n-lint.timer"
  print -r -- "[Service]" > "$units/a5n-lint.service"
  CFG_SCHEDULE="$sched" machine_config m1 on yes alpha
  out="$(a5n m1 setup.sh 2>&1)"
  has "the off timer is removed" "$out" "a5n-lint.timer removed (off in config)"
  check "its timer file is gone" test ! -e "$units/a5n-lint.timer"
  check "its service file is gone" test ! -e "$units/a5n-lint.service"
  has "it was disabled" "$(calls systemctl)" "--user disable --now a5n-lint.timer"
  has "ingest is installed" "$(calls systemctl)" "--user enable --now a5n-ingest.timer"
  has "a stopped run is not a failed unit" "$(cat "$units/a5n-ingest.service")" \
    "SuccessExitStatus=143 130 129"
  has "digest is installed" "$(calls systemctl)" "--user enable --now a5n-digest.timer"
  has_not "lint is not installed" "$(calls systemctl)" "enable --now a5n-lint.timer"

  touch -d '2020-01-02 03:04:05' "$v/alpha/raw/sessions/.gitkeep"
  a5n m1 setup.sh > /dev/null 2>&1
  attr="$(git -C "$v" rev-parse --git-path info/attributes)"
  [[ "$attr" = /* ]] || attr="$v/$attr"
  check_eq "the union line is written once" 1 "$(grep -cxF '**/log.md merge=union' "$attr")"
  check_eq "root log.md merges by union" "log.md: merge: union" \
    "$(git -C "$v" check-attr merge -- log.md)"
  check_eq "project log.md merges by union" "alpha/log.md: merge: union" \
    "$(git -C "$v" check-attr merge -- alpha/log.md)"
  check_eq "an existing .gitkeep keeps its mtime" "2020-01-02 03:04:05" \
    "$(date -r "$v/alpha/raw/sessions/.gitkeep" '+%F %T')"
  check "the vault carries no .gitattributes" test ! -e "$v/.gitattributes"

  # raw_remote while raw/ is tracked: a warning, not a stop.
  machine_config m2 on yes alpha
  mkdir -p "$W/m2/vault"
  git -C "$W/m2/vault" init -q -b main
  git -C "$W/m2/vault" remote add origin "$W/origin.git"
  out="$(a5n m2 setup.sh 2>&1)"
  has "tracked raw/ is warned about" "$out" "raw/ is tracked by git while sync.raw_remote is set"

  export XDG_CONFIG_HOME="$HOME/.config"
}

t_notify_linux() {
  world notify
  machine_config m1 off yes alpha
  machine_local m1
  # A missing unit prompt is a failure the ingest reports at once.
  A5N_PROMPT_FILE="$W/missing.md" a5n m1 daily-ingest.sh
  has "notify-send got the title" "$(calls notify)" "--app-name=A5N A5N ingest"
  has "notify-send got the message" "$(calls notify)" "unit prompt missing or empty"
  forget_calls
  A5N_NO_NOTIFY=1 A5N_PROMPT_FILE="$W/missing.md" a5n m1 daily-ingest.sh
  check_eq "A5N_NO_NOTIFY silences it" "" "$(calls notify)"
}

# macOS has no timeout(1), and osascript ran with no bound: a notification
# that hung held its run, and the run's local lock, for good, since a live
# A5N run keeps its lock however old. Nothing here is macOS: uname answers
# Darwin for this scenario only, and A5N_OSASCRIPT stands in for
# /usr/bin/osascript, which no PATH shim can reach.
t_notify_mac() {
  world notifymac
  machine_config m1 off yes alpha
  machine_local m1
  local v="$W/m1/vault" start took pid
  mkdir -p "$W/darwin"
  print -r -- '#!/bin/sh
echo Darwin' > "$W/darwin/uname"
  # It hangs and ignores TERM too, so only the KILL ends it. An ignored
  # signal stays ignored across exec, and the sleep is the whole process.
  print -r -- "#!/bin/sh
trap '' TERM
echo \$\$ > '$W/osascript.pid'
printf '%s\n' \"\$*\" >> '$W/calls/osascript.log'
exec sleep 40" > "$W/osascript"
  chmod +x "$W/darwin/uname" "$W/osascript"
  start=$SECONDS
  # A missing unit prompt: the ingest notifies while it holds the lock.
  PATH="$W/darwin:$PATH" A5N_OSASCRIPT="$W/osascript" A5N_PROMPT_FILE="$W/missing.md" \
    a5n m1 daily-ingest.sh
  took=$(( SECONDS - start ))
  has "osascript got the title" "$(calls osascript)" 'with title "A5N ingest"'
  has "osascript got the message" "$(calls osascript)" "unit prompt missing or empty"
  check_eq "notify-send is not used on macOS" "" "$(calls notify)"
  check "a hung notification ends after 10s and a 5s grace" test "$took" -lt 20
  check "the run left no lock behind" test ! -e "$v/.a5n-logs/.lock"
  pid="$(cat "$W/osascript.pid" 2>/dev/null)"
  check "the hung notification was killed" sh -c "[ -n '$pid' ] && ! kill -0 '$pid' 2>/dev/null"
}

t_interrupted_unit() {
  world interrupted
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  session m1 alpha "$A2" 2026-09-02
  local v="$W/m1/vault" drv
  # The worker writes half a page and sleeps; the whole run is killed the
  # way a stopped service or a flat battery kills it.
  A5N_CONFIG="$W/m1/config.ini" FAKE_RUNNER_SLEEP=30 FAKE_RUNNER_PIDFILE="$W/runner.pid" \
    setsid zsh "$REPO/scripts/daily-ingest.sh" &
  drv=$!
  wait_for "the worker started" "[ -s '$W/runner.pid' ]" || return
  kill -9 -- "-$drv" 2>/dev/null
  wait "$drv" 2>/dev/null
  check "the unit flag survived the kill" test -e "$v/.a5n-logs/.unit-in-progress"
  check "half a page is on disk" test -n "$(git -C "$v" status --porcelain)"

  a5n m1 daily-ingest.sh
  has "the leftovers went to the stash" "$(git -C "$v" stash list)" \
    "a5n: interrupted unit (ingest alpha/${A1:0:8}"
  has_not "no manual changes commit swallowed them" "$(git -C "$v" log --format=%s)" \
    "manual vault changes"
  check_eq "the first session has one page" 1 "$(pages_for "$v" "$A1")"
  check_eq "the second session has one page" 1 "$(pages_for "$v" "$A2")"
  check "the flag is gone" test ! -e "$v/.a5n-logs/.unit-in-progress"
  has "the user was told where to look" "$(calls notify)" "git stash list"
}

t_two_machines() {
  world two
  machine_config m1 on no alpha gamma
  machine_config m2 on no beta gamma
  machine_new m1
  session m1 alpha "$A1" 2026-09-01
  session m1 gamma "$G1" 2026-09-02
  session m1 alpha "$S1" 2026-09-03 small
  a5n m1 daily-ingest.sh
  check_eq "m1 pushed its first page" 1 "$(remote_pages_for "$A1")"
  has "m1's skip line reached the remote" "$(remote_file alpha/log.md)" "skip | $S1"
  check "m1's raw file is in storage" test -f "$W/drive/alpha/raw/sessions/$A1.jsonl"

  machine_clone m2
  session m2 beta "$B1" 2026-09-04
  session m2 gamma "$G2" 2026-09-05
  a5n m2 daily-ingest.sh
  local v1="$W/m1/vault" v2="$W/m2/vault" sid
  check "m2 downloaded m1's alpha raw file" test -f "$v2/alpha/raw/sessions/$A1.jsonl"
  check "m2 downloaded m1's gamma raw file" test -f "$v2/gamma/raw/sessions/$G1.jsonl"
  check_eq "m2 did not redo m1's gamma session" 1 "$(pages_for "$v2" "$G1")"
  check_eq "m2 processed its beta session" 1 "$(pages_for "$v2" "$B1")"
  check_eq "m2 processed its gamma session" 1 "$(pages_for "$v2" "$G2")"

  a5n m1 daily-ingest.sh
  check "m1 got m2's raw file" test -f "$v1/beta/raw/sessions/$B1.jsonl"
  check_eq "m1 got m2's page" 1 "$(pages_for "$v1" "$B1")"
  for sid in "$A1" "$G1" "$B1" "$G2"; do
    check_eq "one page for ${sid:0:8} on the remote" 1 "$(remote_pages_for "$sid")"
    check "raw ${sid:0:8} is in storage" test -n "$(find "$W/drive" -name "$sid.jsonl")"
  done
  check_eq "m1 is where the remote is" "$(remote_head)" "$(local_head m1)"
  check_eq "no conflict markers" "" "$(grep -rl '^<<<<<<<' "$v1" "$v2" --include='*.md' 2>/dev/null)"
  check_eq "no notification" "" "$(calls notify)"
}

t_offline() {
  world offline
  machine_config m1 on no alpha
  machine_new m1
  session m1 alpha "$A1" 2026-09-01
  a5n m1 daily-ingest.sh
  session m1 alpha "$A2" 2026-09-02
  session m1 alpha "$S1" 2026-09-03 small
  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  a5n m1 daily-ingest.sh
  local v="$W/m1/vault"
  has "the run said it is offline" "$(vlog m1)" "unreachable, working offline"
  check "the raw file was captured" test -f "$v/alpha/raw/sessions/$A2.jsonl"
  has "the capture commit exists locally" "$(git -C "$v" log -1 --format=%s)" "chore: raw capture"
  check_eq "no unit ran offline" 0 "$(pages_for "$v" "$A2")"
  check_eq "rclone was never called offline" "" "$(calls rclone)"
  check "the failure clock started" test -s "$v/.a5n-logs/.sync-failing-since"
  check_eq "one failed run is quiet" "" "$(calls notify)"

  print -r -- "$(( $(date +%s) - 90000 ))" > "$v/.a5n-logs/.sync-failing-since"
  a5n m1 daily-ingest.sh
  has "a day of failing sync notifies" "$(calls notify)" "sync has been failing"

  mv "$W/origin.away" "$W/origin.git"
  a5n m1 daily-ingest.sh
  check_eq "back online the queue ran" 1 "$(pages_for "$v" "$A2")"
  check_eq "and everything is pushed" "$(remote_head)" "$(local_head m1)"
  check "the failure clock was reset" test ! -e "$v/.a5n-logs/.sync-failing-since"
  check "the offline raw file reached storage" test -f "$W/drive/alpha/raw/sessions/$A2.jsonl"
}

t_log_union() {
  world union
  machine_config m1 on no gamma
  machine_config m2 on no gamma
  machine_new m1
  a5n m1 daily-ingest.sh
  machine_clone m2
  a5n m2 daily-ingest.sh
  # m1 pushes a skip line; m2 has an unpushed hand edit to the same log.
  session m1 gamma "$S1" 2026-09-03 small
  a5n m1 daily-ingest.sh
  printf '\n## [2026-09-04] note | typed by hand on m2\n' >> "$W/m2/vault/gamma/log.md"
  a5n m2 daily-ingest.sh
  local log2
  log2="$(cat "$W/m2/vault/gamma/log.md")"
  has "m1's line is on m2" "$log2" "skip | $S1"
  has "m2's line is still there" "$log2" "typed by hand on m2"
  has_not "no conflict markers" "$log2" "<<<<<<<"
  check_eq "m2 pushed the merge" "$(remote_head)" "$(local_head m2)"

  # A refused unit push: m1 appends to the same log while m2's unit runs.
  session m2 gamma "$G2" 2026-09-05
  cat > "$W/hook.sh" <<EOF
cd '$W/m1/vault'
git pull -q --rebase origin main
printf '\n## [2026-09-05] note | from m1 mid unit\n' >> gamma/log.md
git commit -qam 'chore: m1 note'
git push -q origin HEAD:main
EOF
  FAKE_RUNNER_HOOK="$W/hook.sh" a5n m2 daily-ingest.sh
  log2="$(remote_file gamma/log.md)"
  has "the unit's line reached the remote" "$log2" "ingest | ${G2:0:8}"
  has "m1's mid unit line survived" "$log2" "from m1 mid unit"
  check_eq "the unit was not dropped" 1 "$(remote_pages_for "$G2")"
}

t_unit_push_conflict() {
  world conflict
  machine_config m1 on no alpha
  machine_config m2 on no beta
  machine_new m1
  a5n m1 daily-ingest.sh
  machine_clone m2
  a5n m2 daily-ingest.sh
  session m2 beta "$B1" 2026-09-04
  # While m2's unit runs, m1 pushes its own line 3 of the root index.md.
  cat > "$W/hook.sh" <<EOF
cd '$W/m1/vault'
git pull -q --rebase origin main
sed -i '3s/.*/edited on m1/' index.md
git commit -qam 'chore: m1 edits the index'
git push -q origin HEAD:main
EOF
  FAKE_RUNNER_HOOK="$W/hook.sh" FAKE_RUNNER_SHARED="edited by a unit on m2" a5n m2 daily-ingest.sh
  local v2="$W/m2/vault"
  has "the drop was logged" "$(vlog m2)" "unit commit dropped after a rebase conflict"
  check_eq "the unit left no page" 0 "$(pages_for "$v2" "$B1")"
  check_eq "m2 follows the remote again" "$(remote_head)" "$(local_head m2)"
  check_eq "m1's edit is on m2" "edited on m1" "$(sed -n 3p "$v2/index.md")"
  a5n m2 daily-ingest.sh
  check_eq "the next run processed the unit" 1 "$(pages_for "$v2" "$B1")"
}

t_foreign_state() {
  world foreign
  machine_config m1 on no alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  local v="$W/m1/vault"
  session m1 alpha "$A1" 2026-09-01

  git -C "$v" checkout -q -b elsewhere
  a5n m1 daily-ingest.sh
  has "another branch is reported" "$(calls notify)" "the vault is on 'elsewhere', sync expects 'main'"
  check "nothing was captured on it" test ! -e "$v/alpha/raw/sessions/$A1.jsonl"
  git -C "$v" checkout -q main

  # A rebase the user started and left in a conflict.
  git -C "$v" checkout -q -b side
  sed -i '3s/.*/side edit/' "$v/index.md"
  git -C "$v" commit -qam "side"
  git -C "$v" checkout -q main
  sed -i '3s/.*/main edit/' "$v/index.md"
  git -C "$v" commit -qam "main"
  git -C "$v" rebase side > /dev/null 2>&1
  forget_calls
  a5n m1 daily-ingest.sh
  has "the user's rebase is reported" "$(calls notify)" "has a rebase in progress, run skipped"
  check "the user's rebase is untouched" test -d "$v/.git/rebase-merge"
  git -C "$v" rebase --abort

  # The same state with A5N's marker: its own interrupted rebase.
  git -C "$v" rebase side > /dev/null 2>&1
  : > "$v/.a5n-logs/.sync-rebase"
  a5n m1 daily-ingest.sh
  has "A5N aborted its own rebase" "$(vlog m1)" "aborted a rebase an interrupted run left behind"
  check "no rebase is left" test ! -d "$v/.git/rebase-merge"
  check_eq "the run went on" 1 "$(pages_for "$v" "$A1")"
}

t_raw_failure() {
  world rawfail
  machine_config m1 on no alpha
  machine_new m1
  session m1 alpha "$A1" 2026-09-01
  chmod 0555 "$W/drive"
  a5n m1 daily-ingest.sh
  chmod 0755 "$W/drive"
  has "the failed upload notified" "$(calls notify)" "raw file copy (upload) failed for: alpha"
  check_eq "the run went on" 1 "$(pages_for "$W/m1/vault" "$A1")"
  check_eq "and pushed" "$(remote_head)" "$(local_head m1)"
  a5n m1 daily-ingest.sh
  check "the next run uploaded the raw file" test -f "$W/drive/alpha/raw/sessions/$A1.jsonl"
}

t_raw_in_git() {
  world rawgit
  CFG_RAW_REMOTE="" machine_config m1 on no alpha
  CFG_RAW_REMOTE="" machine_config m2 on no alpha
  # raw/ stays in git: the template .gitignore does not exclude it.
  mkdir -p "$W/m1/vault"
  git -C "$W/m1/vault" init -q -b main
  git -C "$W/m1/vault" remote add origin "$W/origin.git"
  a5n m1 setup.sh > /dev/null 2>&1
  session m1 alpha "$A1" 2026-09-01
  a5n m1 daily-ingest.sh
  machine_clone m2
  a5n m2 daily-ingest.sh
  check "the raw file came through git" test -f "$W/m2/vault/alpha/raw/sessions/$A1.jsonl"
  check_eq "rclone was never called" "" "$(calls rclone)"
  check_eq "m2 did not redo the unit" 1 "$(pages_for "$W/m2/vault" "$A1")"
}

t_bounded() {
  world bounded
  local start=$SECONDS rc
  (
    LOGDIR="$W" LOG="$W/log" LOCK="$W/lock" VAULT="$W"
    log() { :; }
    notify_fail() { :; }
    source "$REPO/scripts/lib/common.sh"
    a5n_bounded 1 sleep 30
  )
  rc=$?
  check "a hung command is cut" test "$rc" -ne 0
  check "within its bound" test $(( SECONDS - start )) -lt 10
  # A command that finishes keeps its exit status: sync_fetch reads
  # ls-remote's 2 ("no such branch") through this wrapper.
  (
    LOGDIR="$W" LOG="$W/log" LOCK="$W/lock" VAULT="$W"
    log() { :; }
    notify_fail() { :; }
    source "$REPO/scripts/lib/common.sh"
    a5n_bounded 5 sh -c 'exit 7'
  )
  check_eq "a finished command keeps its exit status" 7 "$?"
}

lock_try() {  # <machine>: one attempt through the library, prints taken or busy
  (
    cd "$W/$1/vault" || exit 1
    eval "$(A5N_CONFIG="$W/$1/config.ini" python3 "$REPO/scripts/config.py" --sh)"
    VAULT="$PWD" LOGDIR="$PWD/.a5n-logs" LOG="$PWD/.a5n-logs/lock-test.log" LOCK="$PWD/.a5n-logs/.lock"
    log() { print -r -- "$*" >> "$LOG"; }
    notify_fail() { log "FAILED: $1"; }
    # lib/sync.sh's contract: lib/common.sh first, its network commands run
    # under a5n_bounded.
    source "$REPO/scripts/lib/common.sh"
    source "$REPO/scripts/lib/sync.sh"
    # Distinct per machine: both subshells share this script's pid, and two
    # identical lock commits would make the race meaningless.
    SYNC_JOB="race-$1"
    if sync_lock_take; then print -r -- taken; else print -r -- busy; fi
  )
}

# A snippet run by a zsh of its own with lib/common.sh sourced for m1's
# vault, so $$ in it is that process's pid. Prints what the snippet prints.
lock_lib() {  # <zsh code>
  zsh -f -c '
    VAULT="$1" LOGDIR="$1/.a5n-logs" LOG="$1/.a5n-logs/lib.log" LOCK="$1/.a5n-logs/.lock"
    log() { print -r -- "$*" >> "$LOG"; }
    notify_fail() { log "FAILED: $1"; }
    source "$2/scripts/lib/common.sh"
    eval "$3"
  ' lock_lib "$W/m1/vault" "$REPO" "$1"
}

# One waiter for m1's local lock, in a process of its own, so its pid is its
# own and stays alive while it holds the lock. It waits for $W/go, makes one
# attempt through the library and writes taken or busy to $W/c<n>. A winner
# holds the lock until $W/over exists.
contender() {  # <n>
  zsh -f -c '
    VAULT="$1" LOGDIR="$1/.a5n-logs" LOG="$1/.a5n-logs/race.log" LOCK="$1/.a5n-logs/.lock"
    log() { print -r -- "$*" >> "$LOG"; }
    notify_fail() { log "FAILED: $1"; }
    source "$2/scripts/lib/common.sh"
    while [ ! -e "$3/go" ] && [ $SECONDS -lt 30 ]; do :; done
    if lock_take; then
      print -r -- taken > "$3/c$4"
      while [ ! -e "$3/over" ] && [ $SECONDS -lt 60 ]; do sleep 0.05; done
    else
      print -r -- busy > "$3/c$4"
    fi
  ' contender "$W/m1/vault" "$REPO" "$W" "$1" 2>> "$W/contenders.err" &
}

t_lock_race() {
  world race
  machine_config m1 on yes alpha
  machine_config m2 on yes beta
  machine_new m1
  a5n m1 daily-ingest.sh
  machine_clone m2
  local round wins
  for round in {1..20}; do
    lock_try m1 > "$W/r1" 2>&1 &
    lock_try m2 > "$W/r2" 2>&1 &
    wait
    wins="$(cat "$W/r1" "$W/r2" | grep -cx taken)"
    if [ "$wins" -ne 1 ]; then
      bad "round $round had $wins winners"
      return
    fi
    git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock
  done
  ok "twenty simultaneous rounds, exactly one winner each"
}

t_lock_busy() {
  world busy
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  check_eq "a finished run leaves no lock" "" "$(remote_lock)"
  fake_lock "host=elsewhere pid=1 job=ingest" now
  session m1 alpha "$A1" 2026-09-01
  session m1 alpha "$S1" 2026-09-03 small
  A5N_SYNC_WAIT=2 a5n m1 daily-ingest.sh
  has "the skip line went out without the lock" "$(remote_file alpha/log.md)" "skip | $S1"
  check "the raw file went up without the lock" test -f "$W/drive/alpha/raw/sessions/$A1.jsonl"
  has "the holder is logged" "$(vlog m1)" "host=elsewhere"
  has "layer 2 was skipped" "$(vlog m1)" "remote lock stayed busy"
  check_eq "no unit ran" 0 "$(pages_for "$W/m1/vault" "$A1")"
  check_eq "the other machine's lock is untouched" "$FAKE_LOCK" "$(remote_lock)"
}

t_lock_wait_requeue() {
  world requeue
  machine_config m1 on yes alpha
  machine_config m2 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  machine_clone m2
  a5n m2 daily-ingest.sh
  fake_lock "host=elsewhere pid=1 job=ingest" now
  session m1 alpha "$A1" 2026-09-01
  session m1 alpha "$A2" 2026-09-02
  A5N_SYNC_WAIT=30 a5n m1 daily-ingest.sh &
  local drv=$! v2="$W/m2/vault"
  wait_for "m1 waits for the lock" "vlog m1 | grep -q 'waiting for the remote lock'" || return
  # Meanwhile the holder processes A1 from the uploaded raw file and leaves.
  git -C "$v2" pull -q --rebase origin main
  (cd "$v2" && "$REPO/tests/fake-runner.sh" -p "A5N-TEST-UNIT
project=alpha
session=$A1
raw=alpha/raw/sessions/$A1.jsonl
date=2026-09-01")
  git -C "$v2" add -A
  git -C "$v2" commit -qm "chore: ingest(alpha) on the other machine"
  git -C "$v2" push -q origin HEAD:main
  git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock
  wait "$drv"
  has "m1 took the lock after waiting" "$(vlog m1)" "remote lock taken"
  has_not "m1 did not start A1" "$(vlog m1)" "unit started: alpha/$A1"
  check_eq "A1 has one page" 1 "$(remote_pages_for "$A1")"
  check_eq "A2 was processed by m1" 1 "$(remote_pages_for "$A2")"
  check_eq "the lock is released" "" "$(remote_lock)"
}

t_lock_stale() {
  world stale
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  fake_lock "host=elsewhere pid=1 job=ingest" old
  a5n m1 daily-ingest.sh
  has "a three hour old lock is taken over" "$(vlog m1)" "took over a stale remote lock"
  check_eq "the unit ran" 1 "$(pages_for "$W/m1/vault" "$A1")"
  check_eq "the lock was released" "" "$(remote_lock)"

  session m1 alpha "$A2" 2026-09-02
  local dead
  dead="$(zsh -c 'print $$')"
  fake_lock "host=$(hostname) pid=$dead job=ingest" now
  a5n m1 daily-ingest.sh
  has "this host's dead owner is taken over at once" "$(vlog m1)" "pid=$dead"
  check_eq "the second unit ran" 1 "$(pages_for "$W/m1/vault" "$A2")"
}

t_lock_lost() {
  world lost
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  session m1 alpha "$A2" 2026-09-02
  # During the first unit another machine takes the lock over.
  cat > "$W/hook.sh" <<EOF
[ -e '$W/hooked' ] && exit 0
: > '$W/hooked'
tree=\$(git --git-dir='$W/origin.git' mktree < /dev/null)
c=\$(git --git-dir='$W/origin.git' commit-tree \$tree -m 'a5n lock: host=elsewhere pid=1 job=ingest at=test')
git --git-dir='$W/origin.git' update-ref refs/a5n/lock \$c
EOF
  FAKE_RUNNER_HOOK="$W/hook.sh" a5n m1 daily-ingest.sh
  has "the lost lock was reported" "$(calls notify)" "taken over by another machine"
  check_eq "the first unit was pushed" 1 "$(remote_pages_for "$A1")"
  check_eq "layer 2 stopped before the second" 0 "$(pages_for "$W/m1/vault" "$A2")"
  has "the new owner's lock was not released" \
    "$(git --git-dir="$W/origin.git" log -1 --format=%s refs/a5n/lock)" "host=elsewhere"
}

t_lock_refused() {
  world refused
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  # A remote that takes branches and refuses every other ref.
  print -r -- '#!/bin/sh
case "$1" in refs/heads/*) exit 0 ;; esac
echo "only branches here" >&2
exit 1' > "$W/origin.git/hooks/update"
  chmod +x "$W/origin.git/hooks/update"
  session m1 alpha "$A1" 2026-09-01
  session m1 alpha "$S1" 2026-09-03 small
  forget_calls
  a5n m1 daily-ingest.sh
  has "the refusal is reported" "$(calls notify)" "refused to create refs/a5n/lock"
  check_eq "it is reported once" 1 "$(calls notify | grep -c 'refused to create')"
  has "the capture still went out" "$(remote_file alpha/log.md)" "skip | $S1"
  check_eq "no unit ran without the lock" 0 "$(pages_for "$W/m1/vault" "$A1")"
}

t_lint_sync() {
  world lint
  machine_config m1 on yes alpha beta
  machine_new m1
  session m1 alpha "$A1" 2026-09-01
  a5n m1 daily-ingest.sh
  a5n m1 weekly-lint.sh
  check "alpha's report reached the remote" test -n "$(remote_file alpha/lint-report.md)"
  check "beta's report reached the remote" test -n "$(remote_file beta/lint-report.md)"
  has "lint took the lock" "$(vlog m1 lint)" "remote lock taken"
  check_eq "and released it" "" "$(remote_lock)"
  check_eq "everything is pushed" "$(remote_head)" "$(local_head m1)"

  fake_lock "host=elsewhere pid=1 job=ingest" now
  forget_calls
  A5N_SYNC_WAIT=2 a5n m1 weekly-lint.sh
  has "a busy lock skips the lint loudly" "$(calls notify)" "lint skipped: the remote lock stayed busy"
  git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock

  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  a5n m1 weekly-lint.sh
  has "offline skips the lint loudly" "$(calls notify)" "lint skipped: origin unreachable"
  mv "$W/origin.away" "$W/origin.git"
}

t_digest_sync() {
  world digest
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  forget_calls
  a5n m1 digest.sh > /dev/null
  local month
  month="$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)"
  check "the digest reached the remote" test -n "$(remote_file "digests/$month.md")"
  has_not "the digest never touches the lock" "$(calls git-net)" "refs/a5n/lock"

  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  a5n m1 digest.sh > /dev/null
  has "offline skips the digest loudly" "$(calls notify)" "digest skipped: origin unreachable"
  mv "$W/origin.away" "$W/origin.git"
}

t_sync_off_identical() {
  local ref="${A5N_BASELINE_REF:-}" base="$TOP/baseline" side scripts
  if [ -z "$ref" ]; then
    print -r -- "  skip  set A5N_BASELINE_REF to the commit to compare against"
    return 0
  fi
  mkdir -p "$base"
  if ! git -C "$REPO" archive "$ref" | tar -x -C "$base"; then
    bad "cannot extract $ref"
    return
  fi
  for side in old new; do
    world "identical-$side"
    machine_config m1 off yes alpha beta
    session m1 alpha "$A1" 2026-09-01
    session m1 alpha "$A2" 2026-09-02
    session m1 beta "$B1" 2026-09-04
    session m1 beta "$S1" 2026-09-03 small
    scripts="$REPO/scripts"
    [ "$side" = old ] && scripts="$base/scripts"
    A5N_CONFIG="$W/m1/config.ini" zsh "$scripts/setup.sh" > /dev/null 2>&1
    A5N_CONFIG="$W/m1/config.ini" zsh "$scripts/daily-ingest.sh"
    A5N_CONFIG="$W/m1/config.ini" zsh "$scripts/weekly-lint.sh"
    A5N_CONFIG="$W/m1/config.ini" zsh "$scripts/digest.sh" > /dev/null
    git -C "$W/m1/vault" log --reverse --format='%s %T' > "$TOP/identical-$side.log"
  done
  check "the runs made commits" test "$(wc -l < "$TOP/identical-new.log")" -ge 6
  check_eq "same commits, same trees" "$(cat "$TOP/identical-old.log")" "$(cat "$TOP/identical-new.log")"
  check_eq "no network call before the change" "" \
    "$(cat "$TOP/identical-old/calls/git-net.log" "$TOP/identical-old/calls/rclone.log" 2>/dev/null)"
  check_eq "no network call after the change" "" \
    "$(cat "$TOP/identical-new/calls/git-net.log" "$TOP/identical-new/calls/rclone.log" 2>/dev/null)"
}

t_lint_prompt() {
  local p
  # Read as prose: the prompt is wrapped, and a sentence may cross a line.
  p="$(tr -s '\n ' ' ' < "$REPO/scripts/prompts/weekly-lint.md")"
  has "the field comes from the vault's CLAUDE.md" "$p" \
    "Read the vault's CLAUDE.md for that field's name and its closed list"
  has_not "state: is no longer the only accepted field" "$p" "out of list \`state:\` value"
}

t_setup_branch() {
  world setupbranch
  local v="$W/m1/vault" out
  export XDG_CONFIG_HOME="$W/xdg"
  # Every run would skip, capture included, on a branch sync does not
  # follow; setup is the place to say so, before a timer exists.
  CFG_SCHEDULE=$'enabled = yes\ningest = 09:07\nlint = off\ndigest = off' \
    machine_config m1 on yes alpha
  mkdir -p "$v"
  print -r -- $'.a5n-logs/\n**/raw/' > "$v/.gitignore"
  git -C "$v" init -q -b master
  git -C "$v" remote add origin "$W/origin.git"
  out="$(a5n m1 setup.sh 2>&1)"
  has "another branch stops setup" "$out" "the vault is on branch 'master' and sync.branch is 'main'"
  # A vault setup created itself can sit on master: renaming is the fix.
  has "the rename is offered" "$out" "branch -m main"
  check_eq "no timer was touched" "" "$(calls systemctl)"
  export XDG_CONFIG_HOME="$HOME/.config"
}

t_raw_dotfiles() {
  world dotfiles
  machine_config m1 on no alpha
  machine_new m1
  local f="$W/m1/vault/alpha/raw/sessions/.DS_Store"
  # Finder drops a .DS_Store into any folder it shows and rewrites it
  # later; to --immutable a rewritten file is a modified one.
  print -r -- "view one" > "$f"
  a5n m1 daily-ingest.sh
  print -r -- "view two, a longer one" > "$f"
  a5n m1 daily-ingest.sh
  check_eq "a rewritten Finder file raises no alarm" "" "$(calls notify)"
  check "it never reached the storage" test ! -e "$W/drive/alpha/raw/sessions/.DS_Store"
}

t_start_conflict() {
  world startconflict
  machine_config m1 on yes alpha
  machine_config m2 on yes beta
  machine_new m1
  a5n m1 daily-ingest.sh
  machine_clone m2
  a5n m2 daily-ingest.sh
  local v1="$W/m1/vault" v2="$W/m2/vault" before
  # m2 pushes line 3 of the root index.md; m1 edits the same line by hand,
  # which its next run commits as a manual change before it pulls.
  sed -i '3s/.*/edited on m2/' "$v2/index.md"
  git -C "$v2" commit -qam "chore: m2 edits the index"
  git -C "$v2" push -q origin HEAD:main
  sed -i '3s/.*/edited on m1/' "$v1/index.md"
  session m1 alpha "$A1" 2026-09-01
  before="$(remote_head)"
  forget_calls
  a5n m1 daily-ingest.sh
  has "the conflict is reported with its path" "$(calls notify)" \
    "local commits conflict with origin/main (index.md)"
  has "capture still ran" "$(vlog m1)" "capture summary: copied=1"
  check "the raw file is on disk" test -f "$v1/alpha/raw/sessions/$A1.jsonl"
  check_eq "no unit ran" 0 "$(pages_for "$v1" "$A1")"
  check "no rebase is left" test ! -d "$v1/.git/rebase-merge"
  check_eq "m1's edit is untouched" "edited on m1" "$(sed -n 3p "$v1/index.md")"
  check_eq "nothing was pushed" "$before" "$(remote_head)"
  has_not "the lock was never tried" "$(calls git-net)" "refs/a5n/lock"
  check "the failure clock started" test -s "$v1/.a5n-logs/.sync-failing-since"
}

t_stopped_run() {
  world stopped
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" script how drv wpid i
  # systemctl stop, launchctl bootout and a shutdown send TERM to the whole
  # group; Ctrl-C on a run by hand sends INT to it, which a worker started
  # with & ignores; `kill <pid>` reaches the driver alone. zsh skips its
  # EXIT trap when an untrapped signal ends it. Each round starts with the
  # previous round's interrupted unit, which the driver recovers first.
  for script in daily-ingest.sh weekly-lint.sh; do
    for how in group-term group-int driver-term; do
      rm -f "$W/runner.pid"
      A5N_CONFIG="$W/m1/config.ini" FAKE_RUNNER_SLEEP=120 FAKE_RUNNER_PIDFILE="$W/runner.pid" \
        setsid zsh "$REPO/scripts/$script" &
      drv=$!
      wait_for "the $script worker started ($how)" "[ -s '$W/runner.pid' ]" || return
      wpid="$(cat "$W/runner.pid")"
      check "$script holds the remote lock mid unit ($how)" test -n "$(remote_lock)"
      case "$how" in
        group-term) kill -TERM -- "-$drv" ;;
        group-int) kill -INT -- "-$drv" ;;
        driver-term) kill -TERM "$drv" ;;
      esac 2>/dev/null
      wait "$drv" 2>/dev/null
      for i in {1..50}; do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
      check "a stopped $script leaves no worker behind ($how)" sh -c "! kill -0 $wpid 2>/dev/null"
      # Nothing else either: a leftover in the unit keeps systemctl stop
      # waiting for its timeout, then the unit is marked failed.
      for i in {1..30}; do [ -z "$(session_left "$drv")" ] && break; sleep 0.1; done
      check_eq "a stopped $script leaves nothing in its session ($how)" "" "$(session_left "$drv")"
      check_eq "a stopped $script releases the remote lock ($how)" "" "$(remote_lock)"
      check "a stopped $script removes its local lock ($how)" test ! -e "$v/.a5n-logs/.lock"
      check "the unit flag stays for the next run ($how)" test -e "$v/.a5n-logs/.unit-in-progress"
    done
  done
}

# With lingering on, a timer starts a run the machine was off for right at
# boot, before anyone logs in, while the keyring holding the git credential
# is still locked. The run waits for the login instead of working offline,
# and asks the remote nothing while it waits.
t_wait_login() {
  world waitlogin
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv asked
  rm -f "$v/.a5n-logs/$TODAY.log"
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run waits for a login" "vlog m1 | grep -q 'waiting for a login'" || return
  asked="$(calls git-net | wc -l)"
  sleep 3
  check_eq "nothing asks the remote while nobody is logged in" "$asked" "$(calls git-net | wc -l)"
  mv "$W/origin.away" "$W/origin.git"
  print -r -- active > "$A5N_TEST_LOGIN"
  wait "$drv"
  has "the log says how long it waited" "$(vlog m1)" "origin reachable after"
  has "after the login the run is in step" "$(vlog m1)" "sync: in step with origin/main"
  has_not "it never worked offline" "$(vlog m1)" "working offline"
  check_eq "layer 2 ran" 1 "$(pages_for "$v" "$A1")"
  check_eq "and pushed" "$(remote_head)" "$(local_head m1)"
  check "no sync failure was counted" test ! -e "$v/.a5n-logs/.sync-failing-since"
  check_eq "no notification" "" "$(calls notify)"
}

# Somebody is logged in and the network comes up late: the run keeps trying.
t_wait_network() {
  world waitnet
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  rm -f "$v/.a5n-logs/$TODAY.log"
  mv "$W/origin.git" "$W/origin.away"
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run keeps trying" "vlog m1 | grep -q 'trying again'" || return
  mv "$W/origin.away" "$W/origin.git"
  wait "$drv"
  has "the run reached the remote" "$(vlog m1)" "sync: in step with origin/main"
  has_not "it never worked offline" "$(vlog m1)" "working offline"
  check_eq "layer 2 ran" 1 "$(pages_for "$v" "$A1")"
  check_eq "and pushed" "$(remote_head)" "$(local_head m1)"
}

# An offline lint or digest is skipped until its next slot, a week or a
# month away: they gain the most from the wait.
t_wait_lint_digest() {
  world waitjobs
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  session m1 alpha "$A1" 2026-09-01
  a5n m1 daily-ingest.sh
  local job name drv month
  month="$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)"
  for job name in weekly-lint.sh lint digest.sh digest; do
    print -r -- lingering > "$A5N_TEST_LOGIN"
    mv "$W/origin.git" "$W/origin.away"
    forget_calls
    A5N_SYNC_RETRY_DELAY=1 a5n m1 "$job" > /dev/null &
    drv=$!
    wait_for "the $name waits for a login" "vlog m1 $name | grep -q 'waiting for a login'" || return
    mv "$W/origin.away" "$W/origin.git"
    print -r -- active > "$A5N_TEST_LOGIN"
    wait "$drv"
    has_not "the $name was not skipped" "$(calls notify)" "skipped"
  done
  check "the lint report reached the remote" test -n "$(remote_file alpha/lint-report.md)"
  check "the digest reached the remote" test -n "$(remote_file "digests/$month.md")"
  check_eq "everything is pushed" "$(remote_head)" "$(local_head m1)"
}

# A credential that needs no login (an ssh key, say) on a machine nobody
# logs in to: the wait ends with one last attempt, which finds the remote
# back.
t_wait_last_try() {
  world waitlast
  CFG_OFFLINE_AFTER=8 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  rm -f "$v/.a5n-logs/$TODAY.log"
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run waits for a login" "vlog m1 | grep -q 'waiting for a login'" || return
  mv "$W/origin.away" "$W/origin.git"
  wait "$drv"
  has "the last attempt reached the remote" "$(vlog m1)" "sync: in step with origin/main"
  check_eq "layer 2 ran" 1 "$(pages_for "$v" "$A1")"
}

# A remote that stays away for the whole wait: the run ends offline exactly
# as it did before the wait existed, and the wait has an end. A hand edit
# made meanwhile gets its own commit instead of riding in the capture's.
t_wait_offline() {
  world waitoff
  CFG_OFFLINE_AFTER=8 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A2" 2026-09-02
  session m1 alpha "$S1" 2026-09-03 small
  local v="$W/m1/vault" start took drv
  rm -f "$v/.a5n-logs/$TODAY.log"
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  start=$SECONDS
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run waits for a login" "vlog m1 | grep -q 'waiting for a login'" || return
  print -r -- "typed by hand while the run waited" >> "$v/index.md"
  wait "$drv"
  took=$(( SECONDS - start ))
  has "then it worked offline" "$(vlog m1)" "unreachable, working offline"
  check "it waited out offline_after" test "$took" -ge 8
  check "and not much longer" test "$took" -lt 25
  # The first run's setup leftovers made a manual changes commit too: the
  # edit's own commit is the last one that touched index.md.
  check_eq "the hand edit has a commit of its own" "chore: manual vault changes (pre-ingest $TODAY)" \
    "$(git -C "$v" log -1 --format=%s -- index.md)"
  check "the raw file was captured" test -f "$v/alpha/raw/sessions/$A2.jsonl"
  has "the capture commit exists locally" "$(git -C "$v" log -1 --format=%s)" "chore: raw capture"
  check_eq "no unit ran offline" 0 "$(pages_for "$v" "$A2")"
  check_eq "rclone was never called offline" "" "$(calls rclone)"
  check "the failure clock started" test -s "$v/.a5n-logs/.sync-failing-since"
  check_eq "one failed run is quiet" "" "$(calls notify)"
  check "the local lock is gone" test ! -e "$v/.a5n-logs/.lock"
  A5N_SYNC_RETRY_DELAY=1 a5n m1 weekly-lint.sh
  has "the lint is still skipped loudly" "$(calls notify)" "lint skipped: origin unreachable"
  forget_calls
  A5N_SYNC_RETRY_DELAY=1 a5n m1 digest.sh > /dev/null
  has "the digest is still skipped loudly" "$(calls notify)" "digest skipped: origin unreachable"
  mv "$W/origin.away" "$W/origin.git"
}

# A machine shut down from the login screen stops a run in the middle of
# its wait, and the wait now lasts minutes where it lasted seconds. Every
# job must leave the way a run stopped mid unit does.
t_wait_stopped() {
  world waitstop
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" script name how drv start i
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  for script name in daily-ingest.sh ingest weekly-lint.sh lint digest.sh digest; do
    for how in group-term driver-term; do
      rm -f "$v/.a5n-logs/"*"$TODAY.log"(N)
      A5N_CONFIG="$W/m1/config.ini" A5N_SYNC_RETRY_DELAY=1 \
        setsid zsh "$REPO/scripts/$script" > /dev/null &
      drv=$!
      wait_for "the $name waits for a login ($how)" "vlog m1 $name | grep -q 'waiting for a login'" || return
      start=$SECONDS
      case "$how" in
        group-term) kill -TERM -- "-$drv" ;;
        driver-term) kill -TERM "$drv" ;;
      esac 2>/dev/null
      wait "$drv" 2>/dev/null
      check "a $name stopped while waiting ends at once ($how)" test $(( SECONDS - start )) -lt 10
      for i in {1..30}; do [ -z "$(session_left "$drv")" ] && break; sleep 0.1; done
      check_eq "the $name leaves nothing in its session ($how)" "" "$(session_left "$drv")"
      check "the $name removes its local lock ($how)" test ! -e "$v/.a5n-logs/.lock"
      has_not "the $name did not go on offline ($how)" "$(vlog m1 $name)" "working offline"
    done
  done
  check "the ingest captured nothing" test ! -e "$v/alpha/raw/sessions/$A1.jsonl"
  mv "$W/origin.away" "$W/origin.git"
}

# The wait ends when somebody logs in, which is when hand edits start. The
# checks before the wait are stale by then. An edit made during the wait
# made git refuse the rebase, and the run reported a conflict that was not
# there and skipped layer 2.
t_wait_dirty() {
  world waitdirty
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  rm -f "$v/.a5n-logs/$TODAY.log"
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run waits for a login" "vlog m1 | grep -q 'waiting for a login'" || return
  print -r -- "typed by hand after the login" >> "$v/index.md"
  mv "$W/origin.away" "$W/origin.git"
  print -r -- active > "$A5N_TEST_LOGIN"
  wait "$drv"
  check_eq "no notification, no false conflict" "" "$(calls notify)"
  check_eq "layer 2 ran" 1 "$(pages_for "$v" "$A1")"
  check_eq "the edit has a commit of its own" "chore: manual vault changes (pre-ingest $TODAY)" \
    "$(git -C "$v" log -1 --format=%s -- index.md)"
  has "and it reached the remote" "$(remote_file index.md)" "typed by hand after the login"
  check_eq "everything is pushed" "$(remote_head)" "$(local_head m1)"
}

# A rebase started by hand during the wait, the very fix A5N's conflict
# notification asks for, stops the run untouched. A5N's own rebase used to
# fail on it and then abort it, the user's resolution with it.
t_wait_user_rebase() {
  world waitrebase
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  git -C "$v" checkout -q -b side
  sed -i '3s/.*/side edit/' "$v/index.md"
  git -C "$v" commit -qam "side"
  git -C "$v" checkout -q main
  rm -f "$v/.a5n-logs/$TODAY.log"
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run waits for a login" "vlog m1 | grep -q 'waiting for a login'" || return
  sed -i '3s/.*/main edit/' "$v/index.md"
  git -C "$v" commit -qam "main edit by hand"
  git -C "$v" rebase side > /dev/null 2>&1
  mv "$W/origin.away" "$W/origin.git"
  print -r -- active > "$A5N_TEST_LOGIN"
  wait "$drv"
  has "the run stopped and said why" "$(calls notify)" "has a rebase in progress, run skipped"
  check "the user's rebase is untouched" test -d "$v/.git/rebase-merge"
  check "nothing was captured" test ! -e "$v/alpha/raw/sessions/$A1.jsonl"
  check "the local lock is gone" test ! -e "$v/.a5n-logs/.lock"
}

# Another branch checked out during the wait stops the run untouched. A5N
# used to rebase that branch, run layer 2 on it and push it to the remote's
# main.
t_wait_branch() {
  world waitbranch
  CFG_OFFLINE_AFTER=60 machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  rm -f "$v/.a5n-logs/$TODAY.log"
  print -r -- lingering > "$A5N_TEST_LOGIN"
  mv "$W/origin.git" "$W/origin.away"
  forget_calls
  A5N_SYNC_RETRY_DELAY=1 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the run waits for a login" "vlog m1 | grep -q 'waiting for a login'" || return
  git -C "$v" checkout -q -b drafts
  print -r -- "a private draft" > "$v/draft.md"
  git -C "$v" add draft.md
  git -C "$v" commit -qm "a draft on another branch"
  mv "$W/origin.away" "$W/origin.git"
  print -r -- active > "$A5N_TEST_LOGIN"
  wait "$drv"
  has "the run stopped and said why" "$(calls notify)" "the vault is on 'drafts', sync expects 'main'"
  check "the draft did not reach the remote" test -z "$(remote_file draft.md)"
  check_eq "the run committed nothing on that branch" "a draft on another branch" \
    "$(git -C "$v" log -1 --format=%s drafts)"
  check "nothing was captured" test ! -e "$v/alpha/raw/sessions/$A1.jsonl"
}

# The wait for the other machine's lock can last an hour, and hand edits
# happen meanwhile. After it the run asks the start's questions again: an
# edit made git refuse the rebase, a conflict that was not there, and layer
# 2 skipped.
t_lock_wait_dirty() {
  world lockwaitdirty
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  fake_lock "host=elsewhere pid=1 job=ingest" now
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  forget_calls
  A5N_SYNC_WAIT=30 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "m1 waits for the remote lock" "vlog m1 | grep -q 'waiting for the remote lock'" || return
  print -r -- "typed by hand during the wait" >> "$v/index.md"
  git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock
  wait "$drv"
  check_eq "no notification, no false conflict" "" "$(calls notify)"
  check_eq "layer 2 ran" 1 "$(pages_for "$v" "$A1")"
  # Setup leftovers made a manual changes commit of their own earlier: the
  # commit that added the typed line is the one to look at.
  check_eq "the edit has a commit of its own" "chore: manual vault changes (pre-ingest $TODAY)" \
    "$(git -C "$v" log -1 --format=%s -S 'typed by hand during the wait' -- index.md)"
  has "and it reached the remote" "$(remote_file index.md)" "typed by hand during the wait"
  check_eq "everything is pushed" "$(remote_head)" "$(local_head m1)"
}

# A rebase started by hand during the wait for the remote lock stops the run
# untouched. A5N's own rebase used to fail on it and then abort it, the
# user's resolution with it.
t_lock_wait_user_rebase() {
  world lockwaitrebase
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  local v="$W/m1/vault" drv
  git -C "$v" checkout -q -b side
  sed -i '3s/.*/side edit/' "$v/index.md"
  git -C "$v" commit -qam "side"
  git -C "$v" checkout -q main
  fake_lock "host=elsewhere pid=1 job=ingest" now
  session m1 alpha "$A1" 2026-09-01
  forget_calls
  A5N_SYNC_WAIT=30 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "m1 waits for the remote lock" "vlog m1 | grep -q 'waiting for the remote lock'" || return
  sed -i '3s/.*/main edit/' "$v/index.md"
  git -C "$v" commit -qam "main edit by hand"
  git -C "$v" rebase side > /dev/null 2>&1
  git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock
  wait "$drv"
  # Capture ran and went out before the wait: only the workers are skipped.
  has "the run stopped and said why" "$(calls notify)" "has a rebase in progress, layer 2 skipped"
  check "the user's rebase is untouched" test -d "$v/.git/rebase-merge"
  check_eq "no unit ran" 0 "$(pages_for "$v" "$A1")"
  check_eq "the remote lock is released" "" "$(remote_lock)"
}

# Another branch checked out during the wait for the remote lock stops the
# run untouched. A5N used to rebase that branch, run layer 2 on it and push
# it to the remote's main.
t_lock_wait_branch() {
  world lockwaitbranch
  machine_config m1 on yes alpha
  machine_new m1
  a5n m1 daily-ingest.sh
  fake_lock "host=elsewhere pid=1 job=ingest" now
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" drv
  forget_calls
  A5N_SYNC_WAIT=30 a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "m1 waits for the remote lock" "vlog m1 | grep -q 'waiting for the remote lock'" || return
  git -C "$v" checkout -q -b drafts
  print -r -- "a private draft" > "$v/draft.md"
  git -C "$v" add draft.md
  git -C "$v" commit -qm "a draft on another branch"
  git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock
  wait "$drv"
  has "the run stopped and said why" "$(calls notify)" \
    "the vault is on 'drafts', sync expects 'main', layer 2 skipped"
  check "the draft did not reach the remote" test -z "$(remote_file draft.md)"
  check_eq "the run committed nothing on that branch" "a draft on another branch" \
    "$(git -C "$v" log -1 --format=%s drafts)"
  check_eq "no unit ran" 0 "$(pages_for "$v" "$A1")"
  check_eq "the remote lock is released" "" "$(remote_lock)"
}

# The lint stopped by the vault check after the wait for the remote lock:
# that check's own notification says why, and no "lint skipped" doubles it.
t_lint_lock_wait() {
  world lintlockwait
  machine_config m1 on yes alpha
  machine_new m1
  session m1 alpha "$A1" 2026-09-01
  a5n m1 daily-ingest.sh
  fake_lock "host=elsewhere pid=1 job=ingest" now
  local v="$W/m1/vault" drv
  forget_calls
  A5N_SYNC_WAIT=30 a5n m1 weekly-lint.sh &
  drv=$!
  wait_for "the lint waits for the remote lock" "vlog m1 lint | grep -q 'waiting for the remote lock'" || return
  git -C "$v" checkout -q -b drafts
  git --git-dir="$W/origin.git" update-ref -d refs/a5n/lock
  wait "$drv"
  has "the lint stopped and said why" "$(calls notify)" "the vault is on 'drafts', sync expects 'main'"
  check_eq "one notification, not two" 1 "$(calls notify | wc -l | tr -d ' ')"
  check_eq "no report reached the remote" "" "$(remote_file alpha/lint-report.md)"
  check_eq "nothing was committed on that branch" "$(git -C "$v" rev-parse main)" \
    "$(git -C "$v" rev-parse drafts)"
  check_eq "the remote lock is released" "" "$(remote_lock)"
}

# Two runs a timer starts at the same boot, an ingest and a lint the machine
# was off for, start in the same second. One of them used to be skipped
# until its next slot, a day or a week away, or both passed the lock check
# and ran in one tree at once. Now one waits for the other.
t_local_same_instant() {
  world localsame
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault"
  FAKE_RUNNER_SLEEP=2 a5n m1 daily-ingest.sh &
  FAKE_RUNNER_SLEEP=2 a5n m1 weekly-lint.sh &
  wait
  check_eq "the ingest processed its session" 1 "$(pages_for "$v" "$A1")"
  check_eq "the lint committed its report" 1 "$(git -C "$v" log --format=%s | grep -c '^chore: lint(alpha)')"
  check_eq "exactly one of them waited" 1 \
    "$({ vlog m1; vlog m1 lint; } | grep -c 'waiting for the local lock')"
  check_eq "their workers never ran at once" "" "$(overlap)"
  check_eq "nothing was skipped" "" "$(calls notify)"
  check "the lock is gone" test ! -e "$v/.a5n-logs/.lock"
}

# A lint catch-up that started at boot still runs when the 09:07 ingest
# fires: the ingest waits for it instead of losing the day.
t_local_wait() {
  world localwait
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" lint
  FAKE_RUNNER_SLEEP=3 FAKE_RUNNER_PIDFILE="$W/runner.pid" a5n m1 weekly-lint.sh &
  lint=$!
  wait_for "the lint worker started" "[ -s '$W/runner.pid' ]" || return
  a5n m1 daily-ingest.sh
  wait "$lint"
  has "the ingest waited" "$(vlog m1)" "waiting for the local lock"
  check_eq "then it processed its session" 1 "$(pages_for "$v" "$A1")"
  check_eq "the lint committed its report" 1 "$(git -C "$v" log --format=%s | grep -c '^chore: lint(alpha)')"
  check_eq "their workers never ran at once" "" "$(overlap)"
  check_eq "nothing was skipped" "" "$(calls notify)"
}

# A holder that never finishes. The wait ends, each job then does what it
# did before the wait existed, and the holder's lock stays as it was. A run
# started by hand on a terminal says that it waits.
t_local_wait_ends() {
  world localwaitends
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" holder start took out
  sleep 300 &
  holder=$!
  print -r -- "$holder" > "$v/.a5n-logs/.lock"
  start=$SECONDS
  A5N_LOCK_WAIT=3 a5n m1 daily-ingest.sh
  took=$(( SECONDS - start ))
  has "the ingest waited" "$(vlog m1)" "waiting for the local lock"
  has "then skipped as before" "$(vlog m1)" "run skipped"
  check "it waited the whole wait" test "$took" -ge 3
  check "and not much longer" test "$took" -lt 15
  check "nothing was captured" test ! -e "$v/alpha/raw/sessions/$A1.jsonl"
  check_eq "the ingest stays quiet, as before" "" "$(calls notify)"
  A5N_LOCK_WAIT=3 a5n m1 weekly-lint.sh
  has "the lint waited" "$(vlog m1 lint)" "waiting for the local lock"
  has "then it was skipped loudly" "$(calls notify)" "lint skipped"
  forget_calls
  A5N_LOCK_WAIT=3 a5n m1 digest.sh > /dev/null
  has "the digest waited" "$(vlog m1 digest)" "waiting for the local lock"
  has "then it was skipped loudly" "$(calls notify)" "digest skipped"
  out="$(A5N_CONFIG="$W/m1/config.ini" A5N_LOCK_WAIT=2 \
    script -qec "zsh ${(q)REPO}/scripts/daily-ingest.sh" /dev/null 2>&1)"
  has "a run on a terminal says it waits" "$out" "waiting"
  has "and that it gives up" "$out" "gives up"
  check_eq "the holder's lock is untouched" "$holder" "$(cat "$v/.a5n-logs/.lock" 2>/dev/null)"
  kill "$holder" 2>/dev/null
}

# systemctl stop, a shutdown or Ctrl-C can stop a run while it waits. It
# leaves at once, and the lock it waited for is the other run's to remove.
t_local_stopped() {
  world localstopped
  machine_config m1 off yes alpha
  machine_local m1
  local v="$W/m1/vault" holder script name how drv start i rc want
  sleep 300 &
  holder=$!
  print -r -- "$holder" > "$v/.a5n-logs/.lock"
  for script name in daily-ingest.sh ingest weekly-lint.sh lint digest.sh digest; do
    for how want in group-term 143 driver-term 143 group-int 130; do
      rm -f "$v/.a5n-logs/"*"$TODAY.log"(N)
      A5N_CONFIG="$W/m1/config.ini" setsid zsh "$REPO/scripts/$script" > /dev/null 2>&1 &
      drv=$!
      wait_for "the $name waits ($how)" "vlog m1 $name | grep -q 'waiting for the local lock'" || {
        kill "$holder" 2>/dev/null; return; }
      start=$SECONDS
      case "$how" in
        group-term) kill -TERM -- "-$drv" ;;
        driver-term) kill -TERM "$drv" ;;
        group-int) kill -INT -- "-$drv" ;;
      esac 2>/dev/null
      wait "$drv" 2>/dev/null
      rc=$?
      check "the $name stopped while waiting ends at once ($how)" test $(( SECONDS - start )) -lt 10
      # The status the unit reads as a stop: the traps are set before the
      # wait, and systemd counts a oneshot a signal killed as failed.
      check_eq "and leaves as a stop ($name, $how)" "$want" "$rc"
      for i in {1..30}; do [ -z "$(session_left "$drv")" ] && break; sleep 0.1; done
      check_eq "the $name leaves nothing in its session ($how)" "" "$(session_left "$drv")"
      check_eq "the holder's lock is still there ($name, $how)" "$holder" \
        "$(cat "$v/.a5n-logs/.lock" 2>/dev/null)"
    done
  done
  kill "$holder" 2>/dev/null
}

# A killed run cannot remove its lock. A dead owner, or a lock two hours
# without a refresh, still frees it at once, with no wait.
t_local_stale() {
  world localstale
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" dead
  dead="$(zsh -fc 'print $$')"
  print -r -- "$dead" > "$v/.a5n-logs/.lock"
  a5n m1 daily-ingest.sh
  has "a dead owner's lock is removed" "$(vlog m1)" "stale lock found (owner pid $dead is dead)"
  check_eq "the run went on" 1 "$(pages_for "$v" "$A1")"
  has_not "without a wait" "$(vlog m1)" "waiting for the local lock"
  session m1 alpha "$A2" 2026-09-02
  rm -f "$v/.a5n-logs/$TODAY.log"
  # A pid that is alive but no A5N run, this script: what the pid of a dead
  # owner looks like once another program got it. Three hours without a
  # touch free such a lock.
  print -r -- $$ > "$v/.a5n-logs/.lock"
  touch -d '3 hours ago' "$v/.a5n-logs/.lock"
  a5n m1 daily-ingest.sh
  has "a lock three hours old is removed" "$(vlog m1)" "stale lock found"
  check_eq "that run went on too" 1 "$(pages_for "$v" "$A2")"
  has_not "without a wait either" "$(vlog m1)" "waiting for the local lock"
  check "each run removed its own lock" test ! -e "$v/.a5n-logs/.lock"
}

# Waiters that find the same stale lock in the same instant: each removed
# it and wrote its own, so the second remove could take the first waiter's
# fresh lock away and both ran. Every round starts from one of the states a
# waiter meets: a dead owner, a lock two hours without a refresh, no lock.
t_local_race() {
  world localrace
  machine_config m1 off yes alpha
  machine_local m1
  local lock="$W/m1/vault/.a5n-logs/.lock" round n wins
  for round in {1..30}; do
    rm -f "$W/go" "$W/over" "$W"/c<1-3>(N)
    case $(( round % 3 )) in
      1) print -r -- "$(zsh -fc 'print $$')" > "$lock" ;;
      2) print -r -- $$ > "$lock"; touch -d '3 hours ago' "$lock" ;;
      0) rm -f "$lock" ;;
    esac
    for n in 1 2 3; do contender "$n"; done
    sleep 0.3
    : > "$W/go"
    if ! wait_for "round $round decided" "[ -s '$W/c1' ] && [ -s '$W/c2' ] && [ -s '$W/c3' ]"; then
      : > "$W/over"
      wait
      return
    fi
    wins="$(cat "$W"/c<1-3> | grep -cx taken)"
    : > "$W/over"
    wait
    if [ "$wins" -ne 1 ]; then
      bad "round $round had $wins winners"
      return
    fi
  done
  ok "thirty rounds of three waiters at once, exactly one winner each"
}

# A suspend, or a raw file copy stuck for an hour per project, can leave a
# running job's lock untouched for more than two hours. A job waiting
# behind it took it for a crashed run's lock: it stashed the running unit's
# half page, notified that a killed run left it, and ran next to it. A live
# A5N run keeps its lock however old the lock is.
t_local_suspend() {
  world localsuspend
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" ing lint
  FAKE_RUNNER_SLEEP=6 FAKE_RUNNER_PIDFILE="$W/runner.pid" a5n m1 daily-ingest.sh &
  ing=$!
  wait_for "the ingest worker started" "[ -s '$W/runner.pid' ]" || return
  # A narrow COLUMNS in the waiter's environment made procps cut the
  # command line short, and the check missed the running driver.
  COLUMNS=20 a5n m1 weekly-lint.sh &
  lint=$!
  wait_for "the lint waits" "vlog m1 lint | grep -q 'waiting for the local lock'" || return
  # What three hours of suspend leave behind: a lock nobody touched since.
  touch -d '3 hours ago' "$v/.a5n-logs/.lock"
  wait "$ing"
  wait "$lint"
  has_not "the lint left the running ingest's lock alone" "$(vlog m1 lint)" "stale lock found"
  has "it waited for the ingest to finish instead" "$(vlog m1 lint)" "local lock taken after"
  check_eq "the running unit was not stashed" "" "$(git -C "$v" stash list)"
  check_eq "no notification" "" "$(calls notify)"
  check_eq "their workers never ran at once" "" "$(overlap)"
  check_eq "the ingest processed its session" 1 "$(pages_for "$v" "$A1")"
  check_eq "the lint committed its report" 1 "$(git -C "$v" log --format=%s | grep -c '^chore: lint(alpha)')"
}

# The lock's small rules, each in a process of its own. A lock with this
# process's own pid was left by an earlier process that had the pid: the
# run used to wait for itself. A lock is empty for an instant after another
# run creates it, and must not be overwritten then, whatever zsh options
# the user's .zshenv sets. And a run removes the lock only while it still
# holds the run's own pid.
t_local_lock_rules() {
  world localrules
  machine_config m1 off yes alpha
  machine_local m1
  local lock="$W/m1/vault/.a5n-logs/.lock"
  check_eq "a lock with this run's own pid is taken" taken \
    "$(lock_lib 'print -r -- $$ > "$LOCK"; lock_take && print taken || print busy')"
  : > "$lock"
  check_eq "an empty lock is not overwritten with CLOBBER_EMPTY set" busy \
    "$(lock_lib 'setopt clobberempty; lock_create && print taken || print busy')"
  check_eq "it is still empty" "" "$(cat "$lock")"
  rm -f "$lock"
  check_eq "a run's exit leaves a lock another pid holds by now" 999999 \
    "$(lock_lib 'lock_take; print -r -- 999999 > "$LOCK"; lock_release; cat "$LOCK" 2>/dev/null')"
}

# The second lock cannot be taken: zsh/system missing, a file system
# without fcntl locks, a file nobody may write. A stale lock then stayed for
# good and every later run waited and skipped. Without the second lock the
# run removes the stale lock the way it did before there was one, and says
# so in its log.
t_local_guard_broken() {
  world localguard
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault"
  mkdir "$v/.a5n-logs/.lock-guard"
  print -r -- "$(zsh -fc 'print $$')" > "$v/.a5n-logs/.lock"
  A5N_LOCK_WAIT=3 a5n m1 daily-ingest.sh
  has "the log says the second lock is missing" "$(vlog m1)" "cannot take the lock guard"
  has "the dead owner's lock was removed anyway" "$(vlog m1)" "stale lock found"
  check_eq "and the run went on" 1 "$(pages_for "$v" "$A1")"
}

# A run whose lock was replaced or removed while it ran must leave the lock
# as it finds it: its exit removes only its own lock, and its touch after a
# unit does not bring a removed lock back as an empty file nobody removes.
t_local_lock_replaced() {
  world localreplaced
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" other
  sleep 300 &
  other=$!
  print -r -- "print -r -- $other > '$v/.a5n-logs/.lock'" > "$W/hook.sh"
  FAKE_RUNNER_HOOK="$W/hook.sh" a5n m1 daily-ingest.sh
  check_eq "another run's lock survives this run's exit" "$other" \
    "$(cat "$v/.a5n-logs/.lock" 2>/dev/null)"
  kill "$other" 2>/dev/null
  wait "$other" 2>/dev/null
  rm -f "$v/.a5n-logs/.lock"
  session m1 alpha "$A2" 2026-09-02
  print -r -- "rm -f '$v/.a5n-logs/.lock'" > "$W/hook.sh"
  FAKE_RUNNER_HOOK="$W/hook.sh" a5n m1 daily-ingest.sh
  check "a removed lock does not come back empty" test ! -e "$v/.a5n-logs/.lock"
}

# The owner of the lock dies while a job waits for it: the next look frees
# the lock and the job runs.
t_local_owner_dies() {
  world localdies
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  local v="$W/m1/vault" holder drv
  sleep 300 &
  holder=$!
  print -r -- "$holder" > "$v/.a5n-logs/.lock"
  a5n m1 daily-ingest.sh &
  drv=$!
  wait_for "the ingest waits" "vlog m1 | grep -q 'waiting for the local lock'" || {
    kill "$holder" 2>/dev/null; return; }
  kill "$holder"
  # Reaped, or kill -0 still finds the pid: a zombie counts as alive.
  wait "$holder" 2>/dev/null
  wait "$drv"
  has "the dead owner's lock was taken over" "$(vlog m1)" "stale lock found (owner pid $holder is dead)"
  check_eq "then the ingest ran" 1 "$(pages_for "$v" "$A1")"
}

# --- runner ------------------------------------------------------------------
# Every function named t_<scenario> is a scenario; each builds its own world.
SCENARIOS=(${(k)functions})
SCENARIOS=(${(M)SCENARIOS:#t_*})
SCENARIOS=(${(o)SCENARIOS#t_})
if [ $# -gt 0 ]; then WANTED=("$@"); else WANTED=("${SCENARIOS[@]}"); fi
for s in "${WANTED[@]}"; do
  CURRENT="$s"
  print -r -- "== $s"
  if (( ! ${+functions[t_$s]} )); then
    bad "no such scenario"
    continue
  fi
  "t_$s"
done

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  print -r -l -- "${FAILURES[@]}"
  print -r -- "kept for inspection: $TOP"
  exit 1
fi
if [ -n "${A5N_KEEP_TEST_DIR:-}" ]; then
  print -r -- "kept: $TOP"
else
  rm -rf "$TOP"
fi
exit 0
