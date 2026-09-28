# Two Machine Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `[sync]` section, off by default, that lets the three A5N drivers keep one vault in step across two machines: pull before work, raw files copied both ways with `rclone copy --immutable`, a push after every commit, and a lock ref on the git remote so one machine at a time runs model workers.

**Architecture:** One sourced zsh library, `scripts/lib/sync.sh`, holds every sync step and returns before running any command when sync is off. A second small library, `scripts/lib/common.sh`, holds what the drivers share that is not sync (desktop notification, interrupted unit flag). The drivers call both at fixed points. `config.py` validates and exports the settings, `setup.sh` checks the remotes and writes the `log.md` union rule. Everything is proven by one end to end script, `tests/sync-e2e.sh`, that builds throwaway worlds (bare repo as remote, rclone `local` remote as storage, two machines) and a fake model runner.

**Tech Stack:** zsh, Python 3.9 standard library, git (2.28 or newer for `init -b`), rclone.

**Spec:** `docs/superpowers/specs/2026-09-28-two-machine-sync-design.md`

## Global Constraints

- Sync off means no network call and commits identical to the pre change code (53af4e9): same subjects, same trees.
- The interrupted unit flag, the `.gitkeep` fix, the lint prompt change and Linux notifications apply with sync off too.
- Code, comments, commit messages and README are English; `README.tr.md` is updated in the same change.
- No em dashes in any prose, comments included (AGENTS.md).
- Comments explain why, naming the failure a safety piece prevents.
- One place per setting: `config.ini` values reach the shell only through `config.py --sh`.
- Nothing runs without a config; tests always pass `A5N_CONFIG`.
- Prompts stay in English.
- No real notes, transcripts, project or machine names anywhere in the repository.
- Do not touch `docs/superpowers/specs/2026-08-08-a5n-gecis-design.md` (untracked in the main checkout, committed separately by the user).
- Exact values: fetch attempts 3, 20 s apart (`A5N_SYNC_RETRY_DELAY`); lock wait 3600 s (`A5N_SYNC_WAIT`), poll 300 s (`A5N_SYNC_POLL`); lock stale after 7200 s; git network commands bounded to 120 s, rclone calls to 3600 s; day rule 86400 s; notify-send bounded to 10 s.
- Lock ref `refs/a5n/lock`, read buffer `refs/a5n/seen-lock`, lock message `a5n lock: host=<host> pid=<pid> job=<job> at=<time>`.
- Flag files in `.a5n-logs/`: `.unit-in-progress`, `.sync-rebase`, `.sync-failing-since`.
- Union rule line, exactly: `**/log.md merge=union`, in the vault's `info/attributes`, never in a `.gitattributes`.
- `config.py` stays Python 3.9 compatible.
- In zsh, a variable directly followed by a colon is written braced, `${var}:...`. zsh reads `$var:r` as a modifier: while this plan was probed, `"$commit:refs/a5n/lock"` silently lost its `:r` and every lock push failed.

## Review Focus

1. Paths with spaces (a vault or storage under `~/My Drive/...`): everything must still work. Pinned in Task 1: the test directory's own name contains spaces, so every scenario runs quoted paths.
2. A git remote that refuses refs outside branches: capture still goes out, layer 2 is skipped, one notification names the cause. Pinned in Task 5, `t_lock_refused`.
3. Cloud storage failing mid run (unreachable, read only): a notification, the run goes on, pages are still pushed, the next run uploads. Pinned in Task 4, `t_raw_failure`.
4. A network command that hangs (stalled TCP, a remote that stops answering): it is cut at its bound and the run carries on. Pinned in Task 4, `t_bounded`.
5. `raw_remote` empty (raw files in git, the default vault layout): rclone is never called and the other machine gets raw files through git. Pinned in Task 4, `t_raw_in_git`.

---

### Task 1: Test harness, fake runner, `[sync]` and `off` in config.py

**Files:**
- Create: `tests/sync-e2e.sh`
- Create: `tests/fake-runner.sh`
- Modify: `scripts/config.py`

**Interfaces:**
- Produces (shell exports from `config.py --sh`): `A5N_SYNC_ENABLED` (`yes|no`), `A5N_SYNC_REMOTE`, `A5N_SYNC_BRANCH`, `A5N_SYNC_RAW_REMOTE` (may be empty, no trailing `/`), `A5N_SYNC_LOCK` (`yes|no`); `A5N_SCHEDULE_INGEST|LINT|DIGEST` may be `off`.
- Produces (test harness helpers, used by every later task): `world <name>`, `machine_config <m> <on|off> <yes|no> <project...>` (honours `CFG_SCHEDULE`, `CFG_RAW_REMOTE`), `machine_new <m>`, `machine_clone <m>`, `machine_local <m>`, `a5n <m> <script> [args]`, `session <m> <project> <id> <date> [small]`, `pages_for <vault> <id>`, `remote_pages_for <id>`, `remote_file <path>`, `remote_head`, `local_head <m>`, `remote_lock`, `vlog <m> [ingest|lint|digest]`, `calls <shim>`, `forget_calls`, `fake_lock <fields> <now|old>` (sets `FAKE_LOCK`), `wait_for <desc> <condition>`, `ok`, `bad`, `check`, `check_eq`, `has`, `has_not`; session ids `A1 A2 B1 G1 G2 S1 S2`; globals `W`, `TOP`, `REPO`, `TODAY`.
- Produces (fake runner switches): `FAKE_RUNNER_HOOK`, `FAKE_RUNNER_SLEEP`, `FAKE_RUNNER_PIDFILE`, `FAKE_RUNNER_SHARED`.

- [ ] **Step 1: Write the harness with its first scenario**

Create `tests/sync-e2e.sh`:

```zsh
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
```

Every later task adds its scenario functions right above the `# --- runner` line.

- [ ] **Step 2: Write the fake runner**

Create `tests/fake-runner.sh` and make it executable (`chmod +x tests/fake-runner.sh`; the drivers execute `runner.bin` directly):

```zsh
#!/bin/zsh
# Stands in for the claude CLI in tests/sync-e2e.sh. The drivers start it as
# "<bin> -p <prompt> --model ...", and the tests hand them prompt templates
# that carry only key=value lines (A5N_PROMPT_FILE, A5N_LINT_PROMPT_FILE),
# so the job is read without parsing the real prompts. It leaves what a real
# worker would leave, and nothing that depends on the clock, so two runs
# over the same fixtures produce the same trees.
#
# Switches, all environment:
#   FAKE_RUNNER_HOOK     a script run before writing: how a test makes "the
#                        other machine" act while a unit is in flight
#   FAKE_RUNNER_SLEEP    write half a page, then sleep this many seconds, so
#                        a test can kill the driver mid unit
#   FAKE_RUNNER_PIDFILE  where to write this process's pid before sleeping
#   FAKE_RUNNER_SHARED   text for line 3 of the root index.md: the shape of
#                        an edit two machines can both make
set -u

prompt="${2:-}"
kind="" project="" session="" raw="" date=""
for line in "${(@f)prompt}"; do
  case "$line" in
    A5N-TEST-UNIT|A5N-TEST-LINT) [ -z "$kind" ] && kind="$line" ;;
    project=*) project="${line#project=}" ;;
    session=*) session="${line#session=}" ;;
    raw=*) raw="${line#raw=}" ;;
    date=*) date="${line#date=}" ;;
  esac
done

[ -n "${FAKE_RUNNER_HOOK:-}" ] && zsh "$FAKE_RUNNER_HOOK"

if [ "$kind" = A5N-TEST-LINT ]; then
  counter=".a5n-logs/fake-lint-count"
  n=$(( $(cat "$counter" 2>/dev/null || print 0) + 1 ))
  print -r -- "$n" > "$counter"
  cat > "$project/lint-report.md" <<EOF
---
title: $project lint report, $date
tags: [$project, lint]
source: manual
date: $date
status: active
---
# $project lint report ($date, weekly)

Fake report number $n.
EOF
  printf '\n## [%s] lint | 0 findings (fake run %s)\n' "$date" "$n" >> "$project/log.md"
  exit 0
fi

if [ "$kind" != A5N-TEST-UNIT ]; then
  print -r -- "fake runner: the prompt is not a test template" >&2
  exit 3
fi

page="$project/sources/sessions/$date-${session:0:8}.md"
mkdir -p "${page:h}"
if [ -n "${FAKE_RUNNER_SLEEP:-}" ]; then
  print -r -- "---" > "$page"
  [ -n "${FAKE_RUNNER_PIDFILE:-}" ] && print -r -- $$ > "$FAKE_RUNNER_PIDFILE"
  sleep "$FAKE_RUNNER_SLEEP"
fi
cat > "$page" <<EOF
---
title: Session ${session:0:8}
tags: [$project, session]
source: $raw
date: $date
status: active
---
# Session ${session:0:8}

Written by tests/fake-runner.sh.

## Sources
- $raw
EOF
printf '\n## [%s] ingest | %s\n' "$date" "${session:0:8}" >> "$project/log.md"
[ -n "${FAKE_RUNNER_SHARED:-}" ] && sed -i "3s/.*/$FAKE_RUNNER_SHARED/" index.md
exit 0
```

- [ ] **Step 3: Run the scenario to see it fail**

Run: `zsh tests/sync-e2e.sh config_validation`
Expected: FAIL lines such as `sync is off by default (no 'export A5N_SYNC_ENABLED='no'')` and `lint may be off`, final line `... failed`, exit 1.

- [ ] **Step 4: Implement `[sync]` and `off` in `scripts/config.py`**

In `DEFAULTS`, after the `"limits"` entry, add:

```python
    "sync": {
        "enabled": "no",
        "remote": "origin",
        "branch": "main",
        "raw_remote": "",
        "lock": "yes",
    },
```

In `load()`, after `_validate_schedule(cfg["schedule"])`, add:

```python
    _validate_sync(cfg["sync"])
```

Replace `_validate_schedule` with:

```python
def _validate_schedule(schedule):
    """A typo here is worse than a failed run: an unparseable schedule used
    to reach setup.sh, whose calendar_keys died only inside a command
    substitution, and the job was installed with an EMPTY launchd calendar,
    which launchd reads as "fire every minute".

    "off" keeps one job off this machine while the others run: a second
    machine sharing a vault leaves lint and digest to the first, because
    both rewrite their output whole."""
    for job in ("ingest", "lint", "digest"):
        spec = schedule[job].strip()
        if spec.lower() == "off":
            schedule[job] = "off"
            continue
        m = SCHEDULE_RX.match(spec)
        day_ok = True
        if m and m.group(1) and m.group(1).isdigit():
            day_ok = 1 <= int(m.group(1)) <= 31
        if not m or not day_ok:
            raise ConfigError(
                f"schedule.{job} '{schedule[job]}' is not valid. Use HH:MM "
                f"(daily), 'sun HH:MM' (weekly), '1 HH:MM' (day of "
                f"month, 1-31) or off."
            )
        schedule[job] = spec
```

After `_validate_schedule`, add:

```python
def _yes_no(key, value):
    v = value.strip().lower()
    if v not in ("yes", "no"):
        raise ConfigError(
            f"{key} is '{value}', must be exactly 'yes' or 'no'.")
    return v


def _validate_sync(sync):
    """Closed values on purpose: "enabled = true" would otherwise leave sync
    silently off while the user believes both machines are in step."""
    sync["enabled"] = _yes_no("sync.enabled", sync["enabled"])
    sync["lock"] = _yes_no("sync.lock", sync["lock"])
    for key in ("remote", "branch"):
        value = sync[key].strip()
        if sync["enabled"] == "yes" and (
                not value or any(c.isspace() for c in value)):
            raise ConfigError(
                f"sync.{key} '{value}' must be one word when sync is "
                f"enabled.")
        sync[key] = value
    raw = sync["raw_remote"].strip()
    sync["raw_remote"] = raw.rstrip("/") or raw
```

In `_emit_shell`, after the `"A5N_SCHEDULE_DIGEST"` line, add:

```python
        "A5N_SYNC_ENABLED": cfg["sync"]["enabled"],
        "A5N_SYNC_REMOTE": cfg["sync"]["remote"],
        "A5N_SYNC_BRANCH": cfg["sync"]["branch"],
        "A5N_SYNC_RAW_REMOTE": cfg["sync"]["raw_remote"],
        "A5N_SYNC_LOCK": cfg["sync"]["lock"],
```

In `main()`, `--check` branch, right after the `print(f"runner: ...")` call, add:

```python
        sync = cfg["sync"]
        if sync["enabled"] == "yes":
            lock = "on" if sync["lock"] == "yes" else "off"
            print(f"sync: on, pages via {sync['remote']}/{sync['branch']}, "
                  f"raw files via {sync['raw_remote'] or 'git'}, lock {lock}")
        else:
            print("sync: off")
```

- [ ] **Step 5: Run the scenario to see it pass**

Run: `zsh tests/sync-e2e.sh config_validation`
Expected: every line `ok`, `N passed, 0 failed`, exit 0.

Run: `python3 -m py_compile scripts/config.py && zsh -n tests/sync-e2e.sh && zsh -n tests/fake-runner.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add tests/sync-e2e.sh tests/fake-runner.sh scripts/config.py
git commit -m "feat: sync settings and schedule off in config, plus the e2e harness"
```

---

### Task 2: setup.sh: placeholders, sync checks, union rule, jobs set to off

**Files:**
- Modify: `scripts/setup.sh`
- Test: `tests/sync-e2e.sh` (add `t_setup_checks`)

**Interfaces:**
- Consumes: Task 1 exports (`A5N_SYNC_*`, `A5N_SCHEDULE_* = off`), harness helpers.
- Produces: vault `info/attributes` containing `**/log.md merge=union` when sync is on; `.gitkeep` files never touched once they exist; timers of `off` jobs removed.

- [ ] **Step 1: Write the failing scenario**

Add to `tests/sync-e2e.sh` above `# --- runner`:

```zsh
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
```

- [ ] **Step 2: Run it to see it fail**

Run: `zsh tests/sync-e2e.sh setup_checks`
Expected: FAIL on `a missing remote stops setup`, `the off timer is removed`, `the union line is written once` and the `.gitkeep` mtime.

- [ ] **Step 3: Placeholders are created, never touched**

In `scripts/setup.sh` replace:

```zsh
mkdir -p "$VAULT"/{patterns,chess-moves,digests,.a5n-logs}
touch "$VAULT/patterns/.gitkeep" "$VAULT/chess-moves/.gitkeep" "$VAULT/digests/.gitkeep"
```

with:

```zsh
mkdir -p "$VAULT"/{patterns,chess-moves,digests,.a5n-logs}
# Placeholders are created once and never touched again: touch refreshed an
# existing one's mtime on every run, and rclone copy --immutable reports a
# file whose mtime changed as modified (exit code 6 on a real vault).
for KEEP in "$VAULT/patterns/.gitkeep" "$VAULT/chess-moves/.gitkeep" "$VAULT/digests/.gitkeep"; do
  [ -e "$KEEP" ] || : > "$KEEP"
done
```

and in the namespace loop replace:

```zsh
    mkdir -p "$NS/$dir"
    touch "$NS/$dir/.gitkeep"
```

with:

```zsh
    mkdir -p "$NS/$dir"
    [ -e "$NS/$dir/.gitkeep" ] || : > "$NS/$dir/.gitkeep"
```

- [ ] **Step 4: Sync checks and the union rule**

In `scripts/setup.sh`, between the `# --- git ---` block (ending `fi` after `say "git repository initialised"`) and `# --- scheduled jobs ---`, insert:

```zsh
# --- sync -----------------------------------------------------------------
# Checked here, before any timer is installed: a scheduled job that cannot
# reach its remote would only fail later, unattended. The README section
# "Two machines, one vault" explains the settings.
if [ "$A5N_SYNC_ENABLED" = "yes" ]; then
  say "checking sync"
  git -C "$VAULT" remote get-url "$A5N_SYNC_REMOTE" >/dev/null 2>&1 \
    || die "sync is on but the vault has no git remote '$A5N_SYNC_REMOTE'. Add it: git -C \"$VAULT\" remote add $A5N_SYNC_REMOTE <url>"
  if [ -n "$A5N_SYNC_RAW_REMOTE" ]; then
    command -v rclone >/dev/null 2>&1 \
      || die "sync.raw_remote is set but rclone is not installed"
    case "$A5N_SYNC_RAW_REMOTE" in
      /*|:*) ;;  # a local path or an on the fly backend: nothing to look up
      *:*)
        RCLONE_NAME="${A5N_SYNC_RAW_REMOTE%%:*}:"
        rclone listremotes 2>/dev/null | grep -qxF -- "$RCLONE_NAME" \
          || die "rclone has no remote named '$RCLONE_NAME'. Create it with: rclone config" ;;
    esac
    FIRST_PROJECT="${${=A5N_PROJECT_NAMES}[1]}"
    if ! git -C "$VAULT" check-ignore -q "$FIRST_PROJECT/raw/sessions/x.jsonl"; then
      say "  warning: raw/ is tracked by git while sync.raw_remote is set, so raw files would travel twice. Add **/raw/ to the vault's .gitignore."
    fi
  fi
  # log.md files only ever grow, so when both machines added lines the right
  # merge keeps both. Machine local on purpose: the vault itself carries no
  # .gitattributes, and every machine that syncs runs this setup anyway.
  ATTR="$(git -C "$VAULT" rev-parse --git-path info/attributes)"
  [[ "$ATTR" = /* ]] || ATTR="$VAULT/$ATTR"
  mkdir -p "${ATTR:h}"
  grep -qxF '**/log.md merge=union' "$ATTR" 2>/dev/null \
    || print -r -- '**/log.md merge=union' >> "$ATTR"
  say "  pages via $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH, raw files via ${A5N_SYNC_RAW_REMOTE:-git}"
fi
```

- [ ] **Step 5: Jobs set to off**

In `scripts/setup.sh`, after the closing `}` of `install_launchd`, add:

```zsh
# A job set to off in config.ini: not installed on this machine, and removed
# when an earlier setup installed it. A second machine sharing a vault turns
# lint and digest off, because both rewrite their output whole.
remove_launchd() {
  local label="$1"
  local plist="$HOME/Library/LaunchAgents/$1.plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  if [ -f "$plist" ]; then
    rm -f "$plist"
    say "  $label removed (off in config)"
  else
    say "  $label off"
  fi
}
```

After the closing `}` of `install_systemd`, add:

```zsh
remove_systemd() {
  local name="$1"
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  if [ -f "$dir/$name.timer" ] || [ -f "$dir/$name.service" ]; then
    systemctl --user disable --now "$name.timer" 2>/dev/null
    rm -f "$dir/$name.timer" "$dir/$name.service"
    systemctl --user daemon-reload 2>/dev/null
    say "  $name.timer removed (off in config)"
  else
    say "  $name.timer off"
  fi
}
```

Replace the whole block from `if [ "$A5N_SCHEDULE_ENABLED" = "yes" ]; then` down to its closing `fi` (just before `# --- first ingest, backfill`) with:

```zsh
# job, script, schedule and description, one row per scheduled job
JOB_ROWS=(
  ingest daily-ingest.sh "$A5N_SCHEDULE_INGEST" "A5N daily ingest"
  lint weekly-lint.sh "$A5N_SCHEDULE_LINT" "A5N weekly lint"
  digest digest.sh "$A5N_SCHEDULE_DIGEST" "A5N monthly digest"
)

if [ "$A5N_SCHEDULE_ENABLED" = "yes" ]; then
  typeset -A CAL
  if [ "$(uname)" = "Darwin" ]; then
    say "installing scheduled jobs"
    # Every calendar is computed and CHECKED before any plist is written: a
    # die() inside $(...) only kills the subshell, and an empty calendar
    # dict means "fire every minute" to launchd. config.py validates the
    # schedule strings too; this is the second seatbelt.
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      [ "$SPEC" = off ] && continue
      CAL[$JOB]="$(calendar_keys "$SPEC")" || die "invalid $JOB schedule: $SPEC"
    done
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      if [ "$SPEC" = off ]; then
        remove_launchd "com.a5n.$JOB"
      else
        install_launchd "com.a5n.$JOB" "$REPO/scripts/$SCRIPT" "${CAL[$JOB]}"
      fi
    done
  elif command -v systemctl >/dev/null 2>&1; then
    say "installing scheduled jobs"
    # Captured and CHECKED before any unit is written, for the same reason
    # the launchd branch above does it: a die() inside $(...) only kills the
    # subshell, and an empty OnCalendar makes systemd refuse the timer.
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      [ "$SPEC" = off ] && continue
      CAL[$JOB]="$(systemd_calendar "$SPEC")" || die "invalid $JOB schedule: $SPEC"
    done
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      if [ "$SPEC" = off ]; then
        remove_systemd "a5n-$JOB"
      else
        install_systemd "a5n-$JOB" "$REPO/scripts/$SCRIPT" "${CAL[$JOB]}" "$DESC"
      fi
    done
    # User timers are torn down at logout unless lingering is on, which
    # turns a working install into one that only fires while you happen to
    # be logged in.
    if [ "$(loginctl show-user "$USER" --property=Linger 2>/dev/null)" != "Linger=yes" ]; then
      say "  note: user lingering is off, so these timers stop when you log out"
      say "  turn it on with: loginctl enable-linger $USER"
    fi
  else
    say "no launchd and no systemd here. Add these to crontab yourself:"
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      [ "$SPEC" = off ] && continue
      say "  $JOB at $SPEC -> $REPO/scripts/$SCRIPT"
    done
  fi
else
  say "scheduling disabled in config, run the scripts by hand when you want them"
fi
```

- [ ] **Step 6: Run the scenario to see it pass**

Run: `zsh tests/sync-e2e.sh setup_checks config_validation`
Expected: all `ok`, exit 0. Then `zsh -n scripts/setup.sh`: no output.

- [ ] **Step 7: Commit**

```bash
git add scripts/setup.sh tests/sync-e2e.sh
git commit -m "feat: setup checks sync remotes, writes the log.md union rule, removes jobs set to off"
```

---

### Task 3: Shared driver helpers: Linux notifications and the interrupted unit stash

**Files:**
- Create: `scripts/lib/common.sh`
- Modify: `scripts/daily-ingest.sh`, `scripts/weekly-lint.sh`, `scripts/digest.sh`
- Test: `tests/sync-e2e.sh` (add `t_notify_linux`, `t_interrupted_unit`)

**Interfaces:**
- Consumes: harness helpers; the driver's `log`, `notify_fail`, `LOGDIR`, `LOG`.
- Produces: `a5n_desktop_notify <title> <message>` (always returns 0), `unit_begin <what>`, `unit_end`, `recover_interrupted_unit` (0 go on, 1 stash failed and notified), `UNIT_FLAG`. Digest gains `notify_fail <message>`.

- [ ] **Step 1: Write the failing scenarios**

Add above `# --- runner`:

```zsh
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `zsh tests/sync-e2e.sh notify_linux interrupted_unit`
Expected: FAIL on `notify-send got the title`, `the unit flag survived the kill`, `the leftovers went to the stash` and `no manual changes commit swallowed them`.

- [ ] **Step 3: Write `scripts/lib/common.sh`**

```zsh
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
```

- [ ] **Step 4: Wire it into `scripts/daily-ingest.sh`**

Replace:

```zsh
notify_fail() {
  log "FAILED: $1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N ingest\"" >/dev/null 2>&1
  fi
}
```

with:

```zsh
notify_fail() {
  log "FAILED: $1"
  a5n_desktop_notify "A5N ingest" "$1"
}

# Shared with the other drivers: the notification itself and the
# interrupted unit flag.
source "$SCRIPT_DIR/lib/common.sh"
```

Replace:

```zsh
# Hand written vault edits should not be mixed into ingest commits. Commit
# them separately under an honest message.
```

with:

```zsh
# Before anything writes: a unit a killed run left half written goes to the
# stash, so the commit below cannot sweep it in as manual edits.
recover_interrupted_unit || exit 1

# Hand written vault edits should not be mixed into ingest commits. Commit
# them separately under an honest message.
```

In the unit loop replace:

```zsh
  UNIT_DONE=""; VREASON=""
  for ATTEMPT in 1 2; do
```

with:

```zsh
  # From here until the commit or rollback below, a kill leaves pages behind.
  unit_begin "ingest $PROJ/${SID:0:8}"
  UNIT_DONE=""; VREASON=""
  for ATTEMPT in 1 2; do
```

and replace:

```zsh
    log "verification REJECTED (attempt $ATTEMPT): $PROJ/$SID, rolled back"
    rollback_unit
  done
```

with:

```zsh
    log "verification REJECTED (attempt $ATTEMPT): $PROJ/$SID, rolled back"
    rollback_unit
  done
  unit_end
```

- [ ] **Step 5: Wire it into `scripts/weekly-lint.sh`**

Replace:

```zsh
notify_fail() {
  log "FAILED: $1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N lint\"" >/dev/null 2>&1
  fi
}
```

with:

```zsh
notify_fail() {
  log "FAILED: $1"
  a5n_desktop_notify "A5N lint" "$1"
}

# Shared with the other drivers: the notification itself and the
# interrupted unit flag.
source "$SCRIPT_DIR/lib/common.sh"
```

Replace:

```zsh
# Hand written edits should not be mixed into lint commits.
```

with:

```zsh
# Before anything writes: a unit a killed run left half written goes to the
# stash, so the commit below cannot sweep it in as manual edits.
recover_interrupted_unit || exit 1

# Hand written edits should not be mixed into lint commits.
```

Replace the mechanical block from `log "fix-links started"` through the mechanical commit's closing `fi` with:

```zsh
unit_begin "lint mechanical repairs"
log "fix-links started"
FIX_OUT="$(python3 "$SCRIPT_DIR/fix-links.py" 2>>"$LOG")"
FIX_RC=$?
echo "$FIX_OUT" >> "$LOG"
if [ "$FIX_RC" -ne 0 ]; then
  notify_fail "fix-links.py failed (rc=$FIX_RC), lint cancelled, leftovers reverted"
  rollback_unit
  unit_end
  exit 1
fi
echo "$FIX_OUT" | head -1 > "$MECHDIR/last-fix-count.txt"

log "lint-mech started"
if ! python3 "$SCRIPT_DIR/lint-mech.py" "$MECHDIR" >> "$LOG" 2>&1; then
  notify_fail "lint-mech.py failed, lint cancelled, leftovers reverted"
  rollback_unit
  unit_end
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  git add -A >> "$LOG" 2>&1
  git commit -m "chore: lint mechanical link repairs $(date +%F)" >> "$LOG" 2>&1
  log "mechanical repairs committed"
fi
unit_end
```

In the project loop replace:

```zsh
  UNIT_DONE=""; VREASON=""
  for ATTEMPT in 1 2; do
```

with:

```zsh
  unit_begin "lint $PROJ"
  UNIT_DONE=""; VREASON=""
  for ATTEMPT in 1 2; do
```

and replace:

```zsh
    log "verification REJECTED (attempt $ATTEMPT): $PROJ, $VREASON"
    rollback_unit
  done
```

with:

```zsh
    log "verification REJECTED (attempt $ATTEMPT): $PROJ, $VREASON"
    rollback_unit
  done
  unit_end
```

- [ ] **Step 6: Wire it into `scripts/digest.sh`**

Replace:

```zsh
  print -r -- "$1"
  log "${2:+FAILED: }$1"
  [ -n "${A5N_NO_NOTIFY:-}" ] && return 0
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/osascript -e "display notification \"$1\" with title \"A5N digest\"" >/dev/null 2>&1
  fi
}
```

with:

```zsh
  print -r -- "$1"
  log "${2:+FAILED: }$1"
  a5n_desktop_notify "A5N digest" "$1"
}
notify_fail() { notify "$1" fail; }

# Shared with the other drivers: the notification itself and the
# interrupted unit flag.
source "$SCRIPT_DIR/lib/common.sh"
```

Replace:

```zsh
# Manual edits stay out of the digest commit, same rule as the other jobs.
```

with:

```zsh
# Before anything writes: a unit a killed run left half written goes to the
# stash, so the commit below cannot sweep it in as manual edits.
recover_interrupted_unit || exit 1

# Manual edits stay out of the digest commit, same rule as the other jobs.
```

Replace:

```zsh
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
```

with:

```zsh
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
```

- [ ] **Step 7: Run the scenarios to see them pass**

Run: `zsh tests/sync-e2e.sh notify_linux interrupted_unit setup_checks config_validation`
Expected: all `ok`, exit 0. Then `zsh -n` on each of the three drivers and on `scripts/lib/common.sh`: no output.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/common.sh scripts/daily-ingest.sh scripts/weekly-lint.sh scripts/digest.sh tests/sync-e2e.sh
git commit -m "feat: stash a unit a killed run left half written, notify on Linux"
```

---

### Task 4: The sync library without the lock, wired into the daily ingest

**Files:**
- Create: `scripts/lib/sync.sh`
- Modify: `scripts/daily-ingest.sh`
- Test: `tests/sync-e2e.sh` (add `t_two_machines`, `t_offline`, `t_log_union`, `t_unit_push_conflict`, `t_foreign_state`, `t_raw_failure`, `t_raw_in_git`, `t_bounded`)

**Interfaces:**
- Consumes: `A5N_SYNC_*`, `A5N_PROJECT_NAMES`, the driver's `log`, `notify_fail`, `VAULT`, `LOGDIR`, `LOG`, `LOCK`.
- Produces: `sync_on`, `sync_bounded <secs> <cmd...>`, `sync_git <args...>`, `sync_recover` (0 go on, 1 stop), `sync_begin <job> <yes|no raw> <yes|no lock>` (sets `SYNC_STATE` to `off|online|offline|blocked`), `sync_publish`, `sync_push` (0 pushed, 1 offline, 2 conflict, 3 refused twice), `sync_push_unit <base commit>` (0 go on, 1 stop layer 2, 2 unit dropped), `sync_ready_for_workers` (0 run, 1 skip; sets `SYNC_REQUEUE`, `SYNC_SKIP_REASON`), `sync_rebase_onto`, `sync_fetch`, `sync_raw <down|up>`, `sync_namespaces`, `sync_ok`, `sync_failed <reason>`. Task 5 adds the lock functions and two lines to `sync_begin` and `sync_ready_for_workers`.

- [ ] **Step 1: Write the failing scenarios**

Add above `# --- runner`:

```zsh
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
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zsh tests/sync-e2e.sh two_machines offline log_union unit_push_conflict foreign_state raw_failure raw_in_git bounded`
Expected: FAIL across the board (nothing is pushed, `scripts/lib/sync.sh` does not exist).

- [ ] **Step 3: Write `scripts/lib/sync.sh`**

```zsh
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
```

- [ ] **Step 4: Wire it into `scripts/daily-ingest.sh`**

In the header comment, after the `# Testing: ...` paragraph, add:

```zsh
#
# With [sync] enabled the run also pulls before work, copies raw files both
# ways, pushes after every commit and holds a lock ref on the remote while
# workers run; scripts/lib/sync.sh has the details and the reasons.
# A5N_SYNC_WAIT / A5N_SYNC_POLL / A5N_SYNC_RETRY_DELAY shorten its waits in
# tests.
```

After `source "$SCRIPT_DIR/lib/common.sh"`, add:

```zsh
# Keeps the vault in step with other machines; every call is a no-op while
# [sync] is off.
source "$SCRIPT_DIR/lib/sync.sh"
```

Replace:

```zsh
# Before anything writes: a unit a killed run left half written goes to the
# stash, so the commit below cannot sweep it in as manual edits.
recover_interrupted_unit || exit 1
```

with:

```zsh
# Before anything writes: with sync, A5N's own interrupted rebase is undone
# and a user's unfinished git operation or another branch stops the run;
# then a unit a killed run left half written goes to the stash, so the
# commit below cannot sweep it in as manual edits.
sync_recover || exit 0
recover_interrupted_unit || exit 1
```

Before `# ---- Layer 1: capture (deterministic)`, add:

```zsh
# With sync: pull, download the other machine's raw files, try the remote
# lock. Capture below runs whatever this finds; it is the only step with a
# deadline.
sync_begin ingest yes yes

```

After the capture commit block (the `fi` after `log "raw capture committed"`), add:

```zsh
# Raw files up, then the commits out, lock or no lock: none of this can race
# the other machine's workers.
sync_publish
```

Replace:

```zsh
if ! python3 "$SCRIPT_DIR/ingest-discover.py" queue > "$QTSV" 2>> "$LOG"; then
  notify_fail "queue step failed, see .a5n-logs/$(date +%F).log"
  exit 1
fi
if [ ! -s "$QTSV" ]; then
  log "queue empty, model never invoked, healthy day"
  exit 0
fi
```

with:

```zsh
build_queue() {
  if ! python3 "$SCRIPT_DIR/ingest-discover.py" queue > "$QTSV" 2>> "$LOG"; then
    notify_fail "queue step failed, see .a5n-logs/$(date +%F).log"
    exit 1
  fi
}
build_queue
if [ ! -s "$QTSV" ]; then
  log "queue empty, model never invoked, healthy day"
  exit 0
fi
# Workers only run in step with the remote and, with the lock on, while
# holding it. A lock that arrives after a wait means the other machine may
# have processed some of these units meanwhile, so the queue is rebuilt.
sync_ready_for_workers || exit 0
if [ "$SYNC_REQUEUE" = 1 ]; then
  build_queue
  if [ ! -s "$QTSV" ]; then
    log "queue empty after the other machine's run, healthy day"
    exit 0
  fi
fi
```

In the unit loop replace:

```zsh
  # From here until the commit or rollback below, a kill leaves pages behind.
  unit_begin "ingest $PROJ/${SID:0:8}"
```

with:

```zsh
  # From here until the commit or rollback below, a kill leaves pages behind.
  UNIT_BASE="$(git rev-parse HEAD)"
  unit_begin "ingest $PROJ/${SID:0:8}"
```

and replace:

```zsh
  unit_end

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), run stopped, queue waits for tomorrow"
      break
    fi
  fi
  touch "$LOCK"
done < "$QTSV"
```

with:

```zsh
  unit_end

  # With sync the commit leaves at once. A conflict drops it (the unit stays
  # queued); an unreachable remote keeps it and stops layer 2.
  PUSH_RC=0
  if [ -n "$UNIT_DONE" ]; then
    sync_push_unit "$UNIT_BASE"
    PUSH_RC=$?
    [ "$PUSH_RC" -eq 2 ] && UNIT_DONE=""
  fi

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), run stopped, queue waits for tomorrow"
      break
    fi
  fi
  [ "$PUSH_RC" -eq 1 ] && break
  touch "$LOCK"
done < "$QTSV"
```

- [ ] **Step 5: Run the scenarios to see them pass**

Run: `zsh tests/sync-e2e.sh two_machines offline log_union unit_push_conflict foreign_state raw_failure raw_in_git bounded`
Expected: all `ok`, exit 0.
Then the earlier ones: `zsh tests/sync-e2e.sh config_validation setup_checks notify_linux interrupted_unit`: all `ok`.
Then `zsh -n scripts/lib/sync.sh` and `zsh -n scripts/daily-ingest.sh`: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/sync.sh scripts/daily-ingest.sh tests/sync-e2e.sh
git commit -m "feat: sync library, the daily ingest pulls, copies raw files and pushes per unit"
```

---

### Task 5: The remote lock

**Files:**
- Modify: `scripts/lib/sync.sh`, `scripts/daily-ingest.sh`
- Test: `tests/sync-e2e.sh` (add `lock_try` helper, `t_lock_race`, `t_lock_busy`, `t_lock_wait_requeue`, `t_lock_stale`, `t_lock_lost`, `t_lock_refused`)

**Interfaces:**
- Consumes: Task 4's `sync_git`, `sync_fetch`, `sync_rebase_onto`, `SYNC_*` globals.
- Produces: `sync_lock_take` (0 taken, 1 not; sets `SYNC_HAVE_LOCK`, `SYNC_LOCK_OID`, `SYNC_LOCK_HOLDER`, `SYNC_LOCK_REFUSED`), `sync_lock_refresh` (0 go on, 1 lock gone, stop), `sync_lock_release`; `sync_begin` takes the lock when its third argument is `yes` and `A5N_SYNC_LOCK=yes`; `sync_ready_for_workers` waits for it.

- [ ] **Step 1: Write the failing scenarios**

Add above `# --- runner`:

```zsh
lock_try() {  # <machine>: one attempt through the library, prints taken or busy
  (
    cd "$W/$1/vault" || exit 1
    eval "$(A5N_CONFIG="$W/$1/config.ini" python3 "$REPO/scripts/config.py" --sh)"
    VAULT="$PWD" LOGDIR="$PWD/.a5n-logs" LOG="$PWD/.a5n-logs/lock-test.log" LOCK="$PWD/.a5n-logs/.lock"
    log() { print -r -- "$*" >> "$LOG"; }
    notify_fail() { log "FAILED: $1"; }
    source "$REPO/scripts/lib/sync.sh"
    # Distinct per machine: both subshells share this script's pid, and two
    # identical lock commits would make the race meaningless.
    SYNC_JOB="race-$1"
    if sync_lock_take; then print -r -- taken; else print -r -- busy; fi
  )
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `zsh tests/sync-e2e.sh lock_race lock_busy lock_wait_requeue lock_stale lock_lost lock_refused`
Expected: FAIL (`sync_lock_take` is not defined; units run while another machine holds the lock).

- [ ] **Step 3: Add the lock to `scripts/lib/sync.sh`**

At the end of `scripts/lib/sync.sh`, append:

```zsh
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
```

In `sync_begin`, replace:

```zsh
  [ "$2" = yes ] && sync_raw down
  return 0
}
```

with:

```zsh
  [ "$2" = yes ] && sync_raw down
  [ "$3" = yes ] && [ "$A5N_SYNC_LOCK" = yes ] && sync_lock_take
  return 0
}
```

In `sync_ready_for_workers`, replace the final lines:

```zsh
      log "sync: blocked by a conflict, layer 2 skipped"
      return 1 ;;
  esac
  return 0
}
```

with:

```zsh
      log "sync: blocked by a conflict, layer 2 skipped"
      return 1 ;;
  esac
  [ "$A5N_SYNC_LOCK" = yes ] || return 0
  [ -n "$SYNC_HAVE_LOCK" ] && return 0
  local waited=0
  while [ -z "$SYNC_LOCK_REFUSED" ] && [ "$waited" -lt "$SYNC_WAIT" ]; do
    [ "$waited" -eq 0 ] && log "sync: waiting for the remote lock (every ${SYNC_POLL}s, at most ${SYNC_WAIT}s): $SYNC_LOCK_HOLDER"
    sleep "$SYNC_POLL"
    waited=$(( waited + SYNC_POLL ))
    touch "$LOCK"
    sync_lock_take || continue
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
```

- [ ] **Step 4: Wire the lock into `scripts/daily-ingest.sh`**

Replace:

```zsh
cleanup() {
  rm -f "$LOCK"
```

with:

```zsh
cleanup() {
  sync_lock_release
  rm -f "$LOCK"
```

and in the unit loop replace:

```zsh
  [ "$PUSH_RC" -eq 1 ] && break
  touch "$LOCK"
done < "$QTSV"
```

with:

```zsh
  [ "$PUSH_RC" -eq 1 ] && break
  touch "$LOCK"
  # The remote lock's twin of the touch above. A lock lost to another
  # machine stops layer 2.
  sync_lock_refresh || break
done < "$QTSV"
```

- [ ] **Step 5: Run everything so far**

Run: `zsh tests/sync-e2e.sh`
Expected: all `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/sync.sh scripts/daily-ingest.sh tests/sync-e2e.sh
git commit -m "feat: one machine at a time runs workers, through a lock ref on the remote"
```

---

### Task 6: Lint and digest with sync

**Files:**
- Modify: `scripts/weekly-lint.sh`, `scripts/digest.sh`
- Test: `tests/sync-e2e.sh` (add `t_lint_sync`, `t_digest_sync`)

**Interfaces:**
- Consumes: every `sync_*` function from Tasks 4 and 5, `SYNC_STATE`, `SYNC_SKIP_REASON`.

- [ ] **Step 1: Write the failing scenarios**

Add above `# --- runner`:

```zsh
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `zsh tests/sync-e2e.sh lint_sync digest_sync`
Expected: FAIL (reports and digest are committed but never pushed, no skip notifications).

- [ ] **Step 3: Wire sync into `scripts/weekly-lint.sh`**

After `source "$SCRIPT_DIR/lib/common.sh"`, add:

```zsh
# Keeps the vault in step with other machines; every call is a no-op while
# [sync] is off.
source "$SCRIPT_DIR/lib/sync.sh"
```

Replace:

```zsh
cleanup() {
  rm -f "$LOCK"
```

with:

```zsh
cleanup() {
  sync_lock_release
  rm -f "$LOCK"
```

Replace:

```zsh
# Before anything writes: a unit a killed run left half written goes to the
# stash, so the commit below cannot sweep it in as manual edits.
recover_interrupted_unit || exit 1
```

with:

```zsh
# Before anything writes: with sync, A5N's own interrupted rebase is undone
# and a user's unfinished git operation or another branch stops the run;
# then a unit a killed run left half written goes to the stash, so the
# commit below cannot sweep it in as manual edits.
sync_recover || exit 0
recover_interrupted_unit || exit 1
```

Before `# --- 1+2. Mechanical layer (deterministic)`, add:

```zsh
# With sync: pull, the raw download, then the remote lock. Every lint step
# edits or reports on pages, so none of it may run next to the other
# machine's workers. The lint already notifies when the local lock makes it
# skip, and these skips follow suit.
sync_begin lint yes yes
case "$SYNC_STATE" in
  offline)
    notify_fail "lint skipped: $A5N_SYNC_REMOTE unreachable; by hand later: scripts/weekly-lint.sh"
    exit 0 ;;
  blocked) exit 0 ;;
esac
if ! sync_ready_for_workers; then
  notify_fail "lint skipped: $SYNC_SKIP_REASON; by hand later: scripts/weekly-lint.sh"
  exit 0
fi

```

Replace:

```zsh
unit_begin "lint mechanical repairs"
```

with:

```zsh
UNIT_BASE="$(git rev-parse HEAD)"
unit_begin "lint mechanical repairs"
```

After the `unit_end` that closes the mechanical step (right before `# --- 3. Semantic lint`), add:

```zsh
sync_push_unit "$UNIT_BASE"
case $? in
  1)
    log "lint stopped: the remote cannot take pushes now, the commits wait for the next run"
    exit 0 ;;
  2) log "mechanical repairs dropped after a conflict, next week's run redoes them" ;;
esac
```

In the project loop replace:

```zsh
  unit_begin "lint $PROJ"
```

with:

```zsh
  UNIT_BASE="$(git rev-parse HEAD)"
  unit_begin "lint $PROJ"
```

and replace:

```zsh
  unit_end

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), lint stopped"
      break
    fi
  fi
  touch "$LOCK"
done
```

with:

```zsh
  unit_end

  # Same rules as the ingest: a conflict drops the report (next week redoes
  # it), an unreachable remote keeps it and stops.
  PUSH_RC=0
  if [ -n "$UNIT_DONE" ]; then
    sync_push_unit "$UNIT_BASE"
    PUSH_RC=$?
    [ "$PUSH_RC" -eq 2 ] && UNIT_DONE=""
  fi

  if [ -n "$UNIT_DONE" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    if [ "$CONSEC_ERR" -ge 2 ]; then
      notify_fail "agent failed $CONSEC_ERR times in a row (API or auth?), lint stopped"
      break
    fi
  fi
  [ "$PUSH_RC" -eq 1 ] && break
  touch "$LOCK"
  sync_lock_refresh || break
done
```

- [ ] **Step 4: Wire sync into `scripts/digest.sh`**

After `source "$SCRIPT_DIR/lib/common.sh"`, add:

```zsh
# Keeps the vault in step with other machines; every call is a no-op while
# [sync] is off.
source "$SCRIPT_DIR/lib/sync.sh"
```

Replace:

```zsh
# Before anything writes: a unit a killed run left half written goes to the
# stash, so the commit below cannot sweep it in as manual edits.
recover_interrupted_unit || exit 1
```

with:

```zsh
# Before anything writes: with sync, A5N's own interrupted rebase is undone
# and a user's unfinished git operation or another branch stops the run;
# then a unit a killed run left half written goes to the stash, so the
# commit below cannot sweep it in as manual edits.
sync_recover || exit 0
recover_interrupted_unit || exit 1
```

Replace:

```zsh
unit_begin "digest"
```

with:

```zsh
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
```

Replace:

```zsh
unit_end

notify "monthly digest ready: $REL_PATH"
```

with:

```zsh
unit_end
sync_push_unit "$UNIT_BASE"
case $? in
  2)
    notify "digest dropped after a conflict with $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH; run scripts/digest.sh by hand" fail
    exit 1 ;;
  1) log "digest committed, it goes out with the next push" ;;
esac

notify "monthly digest ready: $REL_PATH"
```

- [ ] **Step 5: Run everything so far**

Run: `zsh tests/sync-e2e.sh`
Expected: all `ok`, exit 0. `zsh -n scripts/weekly-lint.sh` and `zsh -n scripts/digest.sh`: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/weekly-lint.sh scripts/digest.sh tests/sync-e2e.sh
git commit -m "feat: lint and digest pull before and push after their work"
```

---

### Task 7: Sync off changes nothing

**Files:**
- Test: `tests/sync-e2e.sh` (add `t_sync_off_identical`)

**Interfaces:**
- Consumes: harness helpers; `git archive` of a baseline commit.

- [ ] **Step 1: Write the scenario**

Add above `# --- runner`:

```zsh
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
```

- [ ] **Step 2: Run it against the commit before this change**

Run: `A5N_BASELINE_REF=53af4e9 zsh tests/sync-e2e.sh sync_off_identical`
Expected: all `ok`. A difference in the log comparison is a regression: find which driver's commits differ (`diff` the two `identical-*.log` files kept in the printed directory) and fix the driver, not the test.

Run: `zsh tests/sync-e2e.sh sync_off_identical`
Expected: the `skip` line, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/sync-e2e.sh
git commit -m "test: prove that sync off leaves every commit as it was"
```

---

### Task 8: The lint reads the bug state field from the vault's schema

**Files:**
- Modify: `scripts/prompts/weekly-lint.md`
- Test: `tests/sync-e2e.sh` (add `t_lint_prompt`)

- [ ] **Step 1: Write the failing scenario**

Add above `# --- runner`:

```zsh
t_lint_prompt() {
  local p
  p="$(cat "$REPO/scripts/prompts/weekly-lint.md")"
  has "the field comes from the vault's CLAUDE.md" "$p" \
    "Read the vault's CLAUDE.md for that field's name and its closed list"
  has_not "state: is no longer the only accepted field" "$p" "out of list \`state:\` value"
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `zsh tests/sync-e2e.sh lint_prompt`
Expected: FAIL on both lines.

- [ ] **Step 3: Generalise check 4 of the prompt**

In `scripts/prompts/weekly-lint.md` replace:

```markdown
4. **Frontmatter, closed enum audit.** Pages with no frontmatter, a
   `status:` outside its list (active|stale|archived), or a missing
   `source:` field; in bugs/, a missing or out of list `state:` value
   (index.md and log.md excluded; the Grep tool is enough). The lists are
   closed, so a plausible looking new value is still a finding.
```

with:

```markdown
4. **Frontmatter, closed enum audit.** Pages with no frontmatter, a
   `status:` outside its list (active|stale|archived), or a missing
   `source:` field; in bugs/, a missing or out of list value in the bug
   state field. Read the vault's CLAUDE.md for that field's name and its
   closed list: the default schema calls it `state:` with
   open|pending|fixed|closed, but a vault may define its own, and the
   vault's definition wins. (index.md and log.md excluded; the Grep tool is
   enough.) The lists are closed, so a plausible looking new value is still
   a finding.
```

- [ ] **Step 4: Run it to see it pass**

Run: `zsh tests/sync-e2e.sh lint_prompt`
Expected: both `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/prompts/weekly-lint.md tests/sync-e2e.sh
git commit -m "fix: the lint audits the bug state field the vault's schema defines"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md`, `README.tr.md`, `config.example.ini`, `AGENTS.md`, `CONTRIBUTING.md`

- [ ] **Step 1: `config.example.ini`**

In the `[schedule]` comment, after `# the month, a bare time means daily.`, add:

```ini
# A job set to off is not scheduled on this machine, and removed if an
# earlier setup installed it. A second machine sharing the vault sets
# lint = off and digest = off (see [sync]).
```

Between the `[limits]` section and the `# One section per project.` comment, add:

```ini
[sync]
# Keep one vault on two machines. Off by default, and while it is off no
# script touches the network. README.md, "Two machines, one vault", has the
# whole story.
enabled = no

# The vault's git remote and branch. Pages travel through them.
remote = origin
branch = main

# Where raw transcripts travel, as an rclone path: each project's files live
# under <raw_remote>/<project>/raw. Empty keeps raw files in git. When you
# set it, put **/raw/ in the vault's .gitignore.
raw_remote =

# A ref on the remote, refs/a5n/lock, lets one machine at a time run model
# workers. Turn it off only if a single machine writes the vault.
lock = yes

```

- [ ] **Step 2: `README.md`**

Between the `## Running it` section and `## Reading it back`, insert:

````markdown
## Two machines, one vault

One vault can live on two machines, say a work desktop and a personal
laptop. Each machine has its own A5N checkout and its own `config.ini`,
listing the projects whose transcripts live there. Pages travel through a
private git remote. Raw transcripts travel with them or, when they are too
big for git, through any storage rclone can reach, every machine keeping a
full copy.

Turn it on in `config.ini` on both machines:

```ini
[sync]
enabled = yes
remote = origin
branch = main
raw_remote = gdrive:my-vault
lock = yes
```

`remote` and `branch` name the vault's git remote. `raw_remote` is an rclone
path; each project's raw files live under `<raw_remote>/<project>/raw`.
Leave it empty to keep raw files in git. When you set it, add `**/raw/` to
the vault's `.gitignore`, or raw files travel twice.

With sync on, every run:

1. pulls first (a fetch, then a rebase of any local commits),
2. downloads the raw files the other machine added,
3. captures new sessions, uploads raw files, then pushes,
4. takes a lock on the remote before any model worker starts, and pushes
   after every processed session.

The lock is a ref on the remote, `refs/a5n/lock`, created only if it does
not exist yet, so when both machines start at once exactly one runs
workers. The other still captures and pushes, then waits up to an hour for
the lock. The lock is refreshed after every session, and one older than two
hours is treated as left behind by a crash.

Nothing is ever deleted or overwritten on either side: raw files are copied
with `rclone copy --immutable`, and pushes are never forced. `log.md` files
only ever grow, so when both machines added lines, both are kept (setup
writes that rule into the vault's `.git/info/attributes`). Any other conflict
stops that machine's workers and notifies you. A session whose push
conflicts is dropped and processed again on the next run.

When the remote cannot be reached, the run still captures and commits
locally, skips the workers, and pushes next time. If sync keeps failing for
more than a day, you get a notification.

On the second machine, set `lint = off` and `digest = off` in `[schedule]`:
lint reports and digests are rewritten whole, so one machine should own
them. Give the two machines different ingest times too, or one of them will
spend its run waiting for the other's lock.

To add the second machine, clone the vault, write its `config.ini` and run
setup. Its first run downloads the raw files.

```bash
git clone <your vault's remote> ~/knowledge-vault
cp config.example.ini config.ini   # in the A5N checkout: [sync] as above
zsh scripts/setup.sh
```

`setup.sh` checks that the git remote and the rclone remote exist before it
installs anything. Your git host has to accept refs outside branches and
tags; if it does not, the first run tells you.
````

In `## How it holds together`, after the bullet that starts `- One lock file is shared by every job`, add:

```markdown
- With sync on, the lock has a second half: a ref on the git remote that
  only one machine at a time can hold while model workers run. It is
  refreshed after every session, so a long run never looks abandoned.
- A run killed in the middle of a session leaves a marker behind. The next
  run moves the half written pages to `git stash` instead of committing
  them as if you had written them.
```

- [ ] **Step 3: `README.tr.md`**

Between `## Çalıştırma` and `## Geri okumak`, insert:

````markdown
## İki makine, tek vault

Tek bir vault iki makinede yaşayabilir, örneğin iş masaüstünde ve şahsi
dizüstünde. Her makinenin kendi A5N klonu ve kendi `config.ini`'si olur;
config'te o makinede transkripti oluşan projeler yer alır. Sayfalar özel bir
git remote'u üzerinden taşınır. Ham transkriptler de onlarla birlikte gider
ya da, git için fazla büyüklerse, rclone'un ulaşabildiği herhangi bir
depolama üzerinden taşınır; her makine tam bir kopya tutar.

İki makinede de `config.ini`'de açarsın:

```ini
[sync]
enabled = yes
remote = origin
branch = main
raw_remote = gdrive:my-vault
lock = yes
```

`remote` ve `branch` vault'un git remote'unu gösterir. `raw_remote` bir
rclone yoludur; her projenin ham dosyaları `<raw_remote>/<proje>/raw`
altında durur. Ham dosyalar git'te kalsın istiyorsan boş bırak. Doldurursan
vault'un `.gitignore`'una `**/raw/` ekle, yoksa ham dosyalar iki yoldan
birden gider.

Sync açıkken her koşu:

1. önce çeker (bir fetch, ardından yerel commit'lerin rebase'i),
2. diğer makinenin eklediği ham dosyaları indirir,
3. yeni oturumları yakalar, ham dosyaları yükler, sonra push eder,
4. herhangi bir model işçisi başlamadan remote'ta bir kilit alır ve işlenen
   her oturumdan sonra push eder.

Kilit remote'ta bir ref'tir, `refs/a5n/lock`, ve sadece henüz yoksa
oluşturulur; iki makine aynı anda başlarsa işçileri tam olarak biri
koşturur. Diğeri yine yakalar ve push eder, sonra kilidi bir saate kadar
bekler. Kilit her oturumdan sonra tazelenir; iki saatten eski bir kilit,
çöken bir koşudan kalmış sayılır.

İki tarafta da hiçbir şey silinmez ya da üzerine yazılmaz: ham dosyalar
`rclone copy --immutable` ile kopyalanır, push'lar asla zorlanmaz. `log.md`
dosyaları sadece büyür, iki makine de satır eklediyse ikisi de tutulur
(setup bu kuralı vault'un `.git/info/attributes` dosyasına yazar). Başka her
çakışma o makinenin işçilerini durdurur ve sana bildirim gönderir. Push'u
çakışan bir oturum düşürülür ve bir sonraki koşuda yeniden işlenir.

Remote'a ulaşılamazsa koşu yine yakalar ve yerelde commit'ler, işçileri
atlar, bir sonraki seferde push eder. Senkron bir günden uzun süre başarısız
olmaya devam ederse bildirim gelir.

İkinci makinede `[schedule]` içinde `lint = off` ve `digest = off` yap: lint
raporları ve digest'ler baştan yazılır, dolayısıyla tek bir makinenin işi
olmalı. İki makinenin ingest saatlerini de farklı yap, yoksa biri koşusunu
diğerinin kilidini bekleyerek geçirir.

İkinci makineyi eklemek için vault'u klonla, o makinenin `config.ini`'sini
yaz ve setup'ı çalıştır. İlk koşusu ham dosyaları indirir.

```bash
git clone <vault'unun remote'u> ~/knowledge-vault
cp config.example.ini config.ini   # A5N klonunda: [sync] yukarıdaki gibi
zsh scripts/setup.sh
```

`setup.sh` bir şey kurmadan önce git remote'unun ve rclone remote'unun var
olduğunu kontrol eder. Git sunucunun dal ve etiket dışındaki ref'leri kabul
etmesi gerekir; etmiyorsa ilk koşu bunu sana söyler.
````

In `## Neden bozulmuyor`, after the bullet that starts `- Tek kilit dosyasını bütün görevler paylaşır`, add:

```markdown
- Sync açıkken kilidin ikinci bir yarısı olur: git remote'unda, model
  işçileri koşarken aynı anda sadece bir makinenin tutabildiği bir ref. Her
  oturumdan sonra tazelenir, dolayısıyla uzun bir koşu asla terk edilmiş
  görünmez.
- Bir oturumun ortasında öldürülen koşu arkasında bir işaret bırakır.
  Sonraki koşu yarım yazılmış sayfaları, sen yazmışsın gibi commit'lemek
  yerine `git stash`'e kaldırır.
```

- [ ] **Step 4: `AGENTS.md`**

In the layout block, after the `scripts/*.py         transcript handling and mechanical lint` line, add:

```
scripts/lib/         functions the drivers source: sync, notification, unit flag
```

and after the `scripts/prompts/ ...` line add:

```
tests/               end to end tests, scratch directories only
```

Replace the `## Testing a change` body up to the closing fence of its first code block with:

````markdown
## Testing a change

Before committing:

```bash
python3 -m py_compile scripts/*.py
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do zsh -n "$f"; done
python3 scripts/config.py --check      # against a scratch config.ini
zsh tests/sync-e2e.sh                  # Linux, needs rclone; scratch only
```

`zsh -n` checks one file per call: with several arguments it parses the
first and passes the rest to it as arguments. `tests/sync-e2e.sh` builds
throwaway worlds (a bare repository as the remote, an rclone local remote as
storage, a fake model runner) and never touches a real vault, timer or
remote. `A5N_BASELINE_REF=<commit>` adds the check that sync off still
produces that commit's exact history.
````

- [ ] **Step 5: `CONTRIBUTING.md`**

Replace:

````markdown
There is no test suite yet. Before opening a PR:

```bash
python3 -m py_compile scripts/*.py
zsh -n scripts/*.sh
```
````

with:

````markdown
Before opening a PR:

```bash
python3 -m py_compile scripts/*.py
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do zsh -n "$f"; done
zsh tests/sync-e2e.sh
```

`tests/sync-e2e.sh` runs on Linux with rclone installed and works in a
temporary directory only.
````

- [ ] **Step 6: Check the prose rules**

Run: `git diff 53af4e9 -- . ':!docs' | grep '^+' | grep -c $'—'`
Expected: `0`. Only the lines this change adds are checked: older comments that predate the rule are not this change's business.

- [ ] **Step 7: Commit**

```bash
git add README.md README.tr.md config.example.ini AGENTS.md CONTRIBUTING.md
git commit -m "docs: two machines, one vault"
```

---

### Task 10: Verification on this machine

**Files:** none changed unless a check fails.

- [ ] **Step 1: The whole suite and the repository checks**

Run: `A5N_BASELINE_REF=53af4e9 zsh tests/sync-e2e.sh`
Expected: `N passed, 0 failed`.

Run: `python3 -m py_compile scripts/*.py` and `for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do zsh -n "$f"; done`
Expected: no output.

- [ ] **Step 2: The new config.py reads this machine's real config**

Run, read only: `A5N_CONFIG=<the main checkout's config.ini> python3 scripts/config.py --check`
Expected: the usual lines plus `sync: off`.

- [ ] **Step 3: A real notification from a timer's environment**

`systemd-run --user` gives a command the environment a timer's service gets. Run:

```bash
systemd-run --user --wait --pipe --collect --quiet \
  -p Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin \
  /bin/zsh -c 'LOGDIR=/tmp; source "$0"; a5n_desktop_notify "A5N test" "notification from a timer environment"' \
  "$PWD/scripts/lib/common.sh"
```

Expected: a desktop notification titled "A5N test" appears; exit 0.

- [ ] **Step 4: Review the branch**

Use superpowers:requesting-code-review on `53af4e9..HEAD`. Fix what it confirms, rerun Step 1, commit the fixes.
