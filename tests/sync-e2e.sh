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
    source "$REPO/scripts/lib/sync.sh"
    sync_bounded 1 sleep 30
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
    source "$REPO/scripts/lib/sync.sh"
    sync_bounded 5 sh -c 'exit 7'
  )
  check_eq "a finished command keeps its exit status" 7 "$?"
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
