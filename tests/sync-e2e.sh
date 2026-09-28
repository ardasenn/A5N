#!/bin/zsh
# End to end tests for A5N's [sync] section and the fixes that shipped with
# it: the interrupted unit stash, .gitkeep placeholders, schedule "off" and
# Linux notifications.
#
# Everything happens inside one temporary directory, whose name contains
# spaces on purpose so every path the drivers handle is exercised quoted. A
# bare repository plays the git remote, an rclone "local" remote plays the
# cloud storage, and each machine gets its own config.ini, vault and
# transcript folder. HOME and XDG_CONFIG_HOME point inside the directory and
# small shims stand in for systemctl, launchctl, loginctl and notify-send, so
# no real vault, timer, remote or desktop notification is ever touched. The
# model is replaced by tests/fake-runner.sh.
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
export A5N_PROMPT_FILE="$TOP/unit-prompt.md" A5N_LINT_PROMPT_FILE="$TOP/lint-prompt.md"
unset A5N_NO_NOTIFY A5N_CONFIG A5N_MAX_UNITS A5N_UNIT_TIMEOUT A5N_LINT_PROJECTS
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
shim loginctl 'echo Linger=yes'
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
  export A5N_TEST_CALLS="$W/calls"
  git init -q --bare -b main "$W/origin.git"
}

# machine_config <machine> <sync on|off> <lock yes|no> <project...>
# CFG_SCHEDULE replaces the [schedule] body, CFG_RAW_REMOTE sync.raw_remote
# (set it empty to keep raw files in git).
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
  has "check says sync is off" "$(cfgout --check)" "sync: off"

  mini "[sync]
enabled = YES
raw_remote = gdrive:vault/"
  out="$(cfgout --sh)"
  has "enabled is normalised" "$out" "export A5N_SYNC_ENABLED='yes'"
  has "a trailing slash is dropped" "$out" "export A5N_SYNC_RAW_REMOTE='gdrive:vault'"
  has "check prints the sync line" "$(cfgout --check)" \
    "sync: on, pages via origin/main, raw files via gdrive:vault, lock on"

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
