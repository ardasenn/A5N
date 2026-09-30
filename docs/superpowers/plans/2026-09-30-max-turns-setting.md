# max_turns Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The worker's turn limit, hardcoded as `--max-turns 80` in both drivers, becomes `[limits] max_turns` in config.ini, 150 by default, validated by config.py.

**Architecture:** `scripts/config.py` owns the default (`DEFAULTS`), validates the value in `load()`, exports it as `A5N_MAX_TURNS` through `--sh` and names it in `--check`. `scripts/daily-ingest.sh` and `scripts/weekly-lint.sh` pass `--max-turns "$A5N_MAX_TURNS"` in their claude branch; the codex branch has no such flag and stays as it is. `tests/sync-e2e.sh` proves the default, a configured value and a refused value, through a fake runner that now records its arguments.

**Tech Stack:** zsh, Python 3.9 standard library (configparser), the end to end harness `tests/sync-e2e.sh` with `tests/fake-runner.sh`.

**Spec:** no separate design doc; the Background section below is the agreed requirement.

## Background

A worker (one headless `claude -p` per session, or per project in the lint) may take at most `--max-turns` turns. A turn is one model reply, with every tool call in it: measured with the installed CLI (2.1.276), a worker limited to 2 turns that read three files in parallel in its first reply and answered in its second was not stopped.

The limit is the literal 80 in `scripts/daily-ingest.sh` and `scripts/weekly-lint.sh`. Between 2026-08-28 and 2026-09-30 ingest workers ran out of turns five times, on transcripts from 0.5 to 1.95 MB (one session on two days in a row), and a weekly lint worker once. Each used its 80 turns in 5 to 11 minutes. The CLI printed `Error: Reached max turns (80)` and exited 1; the driver logged `agent exit=1` and rolled the unit back, and an ingest unit stayed queued. `unit_timeout` (1800 s by default) still bounds each worker's wall clock, so a higher turn limit stays bounded in time and cost.

What the CLI does with other values, measured the same day: `--max-turns abc` is refused (`argument 'abc' is invalid. must be a number`), which in a driver would fail every worker of every run; `--max-turns 0` and `--max-turns 1.5` are taken without complaint and the worker runs. So config.py validates the value instead of trusting the CLI.

Decisions:

- One key, `[limits] max_turns`, for both drivers: the weekly lint's workers get the same limit, as they get the same `unit_timeout`, and one of them ran out of turns too.
- Default 150. At the observed pace (80 turns in 5 to 11 minutes) 150 turns fit in the default 30 minute `unit_timeout`.
- Valid: a whole number, 1 or more. Leading zeros are dropped (`0150` becomes `150`). Anything else is a config error, so no driver starts a worker with it.
- Not overridable from the environment: `ENV_OVERRIDABLE` in config.py stays as it is. Tests set the value through their config files.
- The claude engine only. `codex exec` has no turn limit; its branch in `start_worker` is unchanged, and `--check` names a turn limit only for claude.
- No README change: neither README lists the `[limits]` keys; `config.example.ini` documents them.

## Global Constraints

- Work only in `/home/arda/A5N-wt-max-turns`, on branch `feat/max-turns-setting`. Never touch `/home/arda/A5N` (the live checkout the scheduled jobs run from), any `config.ini`, a real vault, systemd timers or a git remote. Do not push.
- Before each commit, `git -C /home/arda/A5N-wt-max-turns branch --show-current` must print `feat/max-turns-setting`.
- No em dash (U+2014) anywhere, comments and commit messages included (AGENTS.md), and no en dash in its place: rebuild the sentence with commas, colons or parentheses.
- Comments explain why, not what (AGENTS.md). Match the surrounding comment density.
- One place per setting: the default 150 lives in `DEFAULTS` in `scripts/config.py`, mirrored in `config.example.ini` like every other key. The drivers read only `$A5N_MAX_TURNS`; the literal 80 leaves both.
- `scripts/config.py` stays Python 3.9 compatible.
- English everywhere. No real project names, machine names or session ids in the repository.
- Exact names: ini key `max_turns` in `[limits]`; shell export `A5N_MAX_TURNS`; error text `limits.max_turns is '<value as written>', must be a whole number, 1 or more.`; the `--check` runner line ends with `, max turns <n>` for the claude engine.
- `zsh -n` checks one file per call (AGENTS.md).
- Tests run only through `tests/sync-e2e.sh`, which builds throwaway worlds in a temporary directory.
- Commit messages follow the repository: a `<type>: <sentence>` subject, a body that says why and what the tests cover, then a `Co-Authored-By:` trailer naming the model that wrote the commit.

## Review Focus

1. A config.ini written before this change has no `max_turns` line (every live machine): the default 150 must apply with no edit. Task 1 (`--sh` default) and Task 2 (both drivers with no such line) pin it.
2. A typo in the value (`0`, `abc`, `1.5`, `-3`, empty): a config error that names the key, and no worker starts. Task 1 (each value) and Task 2 (a driver stops before its worker) pin it.
3. A value written with leading zeros (`0200`): read as 200, not refused. Task 1 pins it.
4. The codex engine: no `--max-turns` is passed and `--check` does not claim a limit. Task 1 pins the `--check` line; the codex branch is not edited.
5. The old drivers against the new test harness: the fake runner's new argument log must not change what `sync_off_identical` compares. Checked after the tasks with `A5N_BASELINE_REF=30d4d7a`.

---

### Task 1: The setting in config.py and config.example.ini

**Files:**
- Modify: `scripts/config.py` (`DEFAULTS`, `load()`, a new `_validate_limits()`, `_emit_shell()`, the `--check` runner line)
- Modify: `config.example.ini` (`[limits]`)
- Test: `tests/sync-e2e.sh` (`t_config_validation`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `cfg["limits"]["max_turns"]`, a string holding a whole number of 1 or more with no leading zeros; the line `export A5N_MAX_TURNS='<n>'` in `config.py --sh` output (always emitted, not environment overridable); the `--check` line `runner: claude (<bin>), model <m>, effort <e>, max turns <n>`.

- [ ] **Step 1: Write the failing tests**

In `tests/sync-e2e.sh`, function `t_config_validation`:

(a) Its first line declares the locals. Replace

```zsh
  local cfg="$W/c.ini" out
```

with

```zsh
  local cfg="$W/c.ini" out bad
```

(b) After these two existing lines

```zsh
  has "the wait for the remote defaults to 15 minutes" "$out" "export A5N_SYNC_OFFLINE_AFTER='900'"
  has "check says sync is off" "$(cfgout --check)" "sync: off"
```

add

```zsh
  has "the turn limit defaults to 150" "$out" "export A5N_MAX_TURNS='150'"
  has "check names the turn limit" "$(cfgout --check)" "effort default, max turns 150"
```

(c) At the end of the function, after

```zsh
  mini "[schedule]
lint = sometimes"
  has "a bad schedule still fails" "$(cfgout --check)" \
    "schedule.lint 'sometimes' is not valid"
```

and before the function's closing `}`, add

```zsh

  mini "[limits]
max_turns = 0200"
  has "leading zeros are dropped from the turn limit" "$(cfgout --sh)" \
    "export A5N_MAX_TURNS='200'"

  # The claude CLI refuses a word here, which fails every worker, and takes
  # 0 or 1.5 without complaint: config.py is the only judge.
  for bad in 0 abc 1.5 -3 ""; do
    mini "[limits]
max_turns = $bad"
    has "max_turns '$bad' is refused" "$(cfgout --check)" \
      "limits.max_turns is '$bad', must be a whole number, 1 or more."
  done

  # codex exec has no turn limit, so check names none.
  print -r -- "[vault]
path = $W/vault
[runner]
engine = codex
bin = /bin/true
[project:alpha]
match = alpha
watermark = 2026-01-01" > "$cfg"
  has "check prints the codex runner" "$(cfgout --check)" "runner: codex (/bin/true)"
  has_not "check names no turn limit for codex" "$(cfgout --check)" "max turns"
```

- [ ] **Step 2: Run the scenario and see it fail**

Run: `cd /home/arda/A5N-wt-max-turns && zsh tests/sync-e2e.sh config_validation`
Expected: exit 1 with exactly 8 `FAIL` lines: "the turn limit defaults to 150", "check names the turn limit", "leading zeros are dropped from the turn limit", and the five "max_turns '...' is refused" checks. The two codex checks already pass (nothing prints a turn limit yet), and every older check still passes.

- [ ] **Step 3: Implement the setting in scripts/config.py**

(a) In `DEFAULTS["limits"]`, after the line `"unit_timeout": "1800",` add:

```python
        "max_turns": "150",
```

(b) In `load()`, after the line `_validate_sync(cfg["sync"])` add:

```python
    _validate_limits(cfg["limits"])
```

(c) Right after the whole `_validate_sync` function (before the comment block that starts `# Effort is a closed list per engine`), add:

```python
def _validate_limits(limits):
    """Only max_turns is checked: it reaches the claude CLI as --max-turns,
    and the CLI is no judge of it. A word there fails every worker, and two
    failures in a row stop the run with a notification that suspects the
    API; 0 or 1.5 is taken without complaint, and the limit is silently not
    the one this file names."""
    turns = limits["max_turns"].strip()
    if not re.fullmatch(r"[0-9]+", turns) or int(turns) < 1:
        raise ConfigError(
            f"limits.max_turns is '{limits['max_turns']}', must be a whole "
            f"number, 1 or more.")
    limits["max_turns"] = str(int(turns))
```

Leave two blank lines around it, as between the other top level functions.

(d) In `_emit_shell()`, after the line `"A5N_UNIT_TIMEOUT": cfg["limits"]["unit_timeout"],` add:

```python
        "A5N_MAX_TURNS": cfg["limits"]["max_turns"],
```

Do not add it to `ENV_OVERRIDABLE`.

(e) In `main()`, the `--check` branch, replace

```python
        print(f"runner: {cfg['runner']['engine']} ({resolved}), "
              f"model {cfg['runner']['model']}, effort {effort}")
```

with

```python
        # codex exec has no turn limit, so only claude's line names one.
        turns = ""
        if cfg["runner"]["engine"] == "claude":
            turns = f", max turns {cfg['limits']['max_turns']}"
        print(f"runner: {cfg['runner']['engine']} ({resolved}), "
              f"model {cfg['runner']['model']}, effort {effort}{turns}")
```

- [ ] **Step 4: Document the key in config.example.ini**

In `[limits]`, after

```ini
# Wall clock ceiling for ONE session's worker, in seconds. There is no
# separate ceiling for the whole run: it is already bounded by
# max_units * unit_timeout.
unit_timeout = 1800
```

add (one blank line before it, as between the other keys):

```ini

# Most turns ONE worker may take, in the daily ingest and the weekly lint
# alike. A turn is one model reply, with every tool call in it. A worker
# that runs out stops with an error and its work is rolled back; an ingest
# unit stays queued for the next run. Some sessions need more than 80.
# unit_timeout above still bounds the time, and with it the cost: 80
# turns have taken 5 to 11 minutes, so 150 fits in the default 30.
# The claude engine only: codex exec has no such limit.
max_turns = 150
```

- [ ] **Step 5: Run the scenario and see it pass**

Run: `python3 -m py_compile scripts/config.py && zsh tests/sync-e2e.sh config_validation`
Expected: exit 0, last line `<n> passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
cd /home/arda/A5N-wt-max-turns
git branch --show-current   # must print feat/max-turns-setting
git add scripts/config.py config.example.ini tests/sync-e2e.sh
git commit -F - <<'EOF'
feat: limits.max_turns, the worker's turn limit, 150 by default

The drivers pass --max-turns 80 to every claude worker, a literal no
config can change, and some sessions ran out of turns at 80 and stayed
queued, one of them day after day. config.py now owns the limit: 150 when config.ini has no
max_turns line, exported as A5N_MAX_TURNS and named in --check for the
claude engine. The value is checked, since the claude CLI refuses a
word there and takes 0 or 1.5 without complaint.

config_validation covers the default, leading zeros, five refused
values and the codex check line, which names no limit.

Co-Authored-By: Claude <your model name> <noreply@anthropic.com>
EOF
```

Replace `<your model name>` with the model you run as, for example `Sonnet 5.5`.

---

### Task 2: Both drivers take the limit from config.ini

**Files:**
- Modify: `scripts/daily-ingest.sh` (the `--max-turns 80` line in `start_worker`)
- Modify: `scripts/weekly-lint.sh` (the `--max-turns 80` line in `start_worker`)
- Modify: `tests/fake-runner.sh` (record the arguments)
- Test: `tests/sync-e2e.sh` (header comment, `machine_config`, a helper, a new scenario `t_max_turns`)

**Interfaces:**
- Consumes: `A5N_MAX_TURNS` from `config.py --sh` (Task 1).
- Produces: `$A5N_TEST_CALLS/runner.log`, one line per fake worker holding every argument after the prompt; the `CFG_MAX_TURNS` knob of `machine_config`; the helper `turns_passed`.

- [ ] **Step 1: The fake runner records its arguments**

In `tests/fake-runner.sh`, in the header comment, replace

```zsh
# Every run writes a start and an end line, with its pid and working
# directory, to $A5N_TEST_CALLS/workers.log: that is how a test sees two
# workers running in one vault at the same time.
```

with

```zsh
# Every run writes a start and an end line, with its pid and working
# directory, to $A5N_TEST_CALLS/workers.log: that is how a test sees two
# workers running in one vault at the same time. It also writes every
# argument after the prompt, one line per run, to
# $A5N_TEST_CALLS/runner.log: that is how a test sees what the driver
# passed, the turn limit among them.
```

and after the line

```zsh
trap 'trace end' EXIT
```

add

```zsh
[ -n "${A5N_TEST_CALLS:-}" ] && print -r -- "${*:3}" >> "$A5N_TEST_CALLS/runner.log"
```

- [ ] **Step 2: The test knob, the helper and the scenario**

(a) In the header comment of `tests/sync-e2e.sh`, replace

```zsh
# desktop notifications, the macOS one through stand ins. The local lock
# the three jobs share is tested here too (the t_local_* scenarios).
```

with

```zsh
# desktop notifications, the macOS one through stand ins. The local lock
# the three jobs share is tested here too (the t_local_* scenarios), and
# the worker's turn limit from config.ini (t_max_turns).
```

(b) The comment above `machine_config()`: replace

```zsh
# sync.offline_after (0 unless set: no wait, the start every scenario before
# the wait was written against).
```

with

```zsh
# sync.offline_after (0 unless set: no wait, the start every scenario before
# the wait was written against), CFG_MAX_TURNS limits.max_turns (no line
# unless set, so the default applies).
```

(c) Inside `machine_config()`, replace

```zsh
unit_timeout = 60
max_units = 15
```

with

```zsh
unit_timeout = 60
max_units = 15
${CFG_MAX_TURNS:+max_turns = $CFG_MAX_TURNS}
```

(d) After the line that defines `forget_calls()`, add:

```zsh
turns_passed() {  # the --max-turns values the fake workers got, one per line
  grep -oE -- '--max-turns [^ ]+' "$W/calls/runner.log" 2>/dev/null | cut -d' ' -f2 | sort -u
}
```

(e) Add a new scenario right after the whole `t_config_validation` function (before `t_setup_checks() {`):

```zsh
# The worker's turn limit comes from limits.max_turns: 150 when config.ini
# has no such line, the configured value otherwise, in both drivers. A
# value config.py refuses stops a driver before any worker starts.
t_max_turns() {
  world maxturns
  local v="$W/m1/vault" out
  machine_config m1 off yes alpha
  machine_local m1
  session m1 alpha "$A1" 2026-09-01
  a5n m1 daily-ingest.sh
  check_eq "the ingest worker gets 150 by default" 150 "$(turns_passed)"
  forget_calls
  a5n m1 weekly-lint.sh
  check_eq "the lint worker gets 150 by default" 150 "$(turns_passed)"

  forget_calls
  CFG_MAX_TURNS=7 machine_config m1 off yes alpha
  session m1 alpha "$A2" 2026-09-02
  a5n m1 daily-ingest.sh
  check_eq "the ingest worker gets the configured limit" 7 "$(turns_passed)"
  forget_calls
  a5n m1 weekly-lint.sh
  check_eq "the lint worker gets the configured limit" 7 "$(turns_passed)"

  forget_calls
  CFG_MAX_TURNS=0 machine_config m1 off yes alpha
  session m1 alpha "$G1" 2026-09-03
  out="$(a5n m1 daily-ingest.sh 2>&1)"
  has "a refused limit stops the ingest" "$out" "limits.max_turns is '0'"
  out="$(a5n m1 weekly-lint.sh 2>&1)"
  has "and the lint" "$out" "limits.max_turns is '0'"
  check_eq "no worker started" "" "$(calls runner)"
  check_eq "the session is still unprocessed" 0 "$(pages_for "$v" "$G1")"
}
```

- [ ] **Step 3: Run the scenario and see it fail**

Run: `cd /home/arda/A5N-wt-max-turns && zsh tests/sync-e2e.sh max_turns`
Expected: exit 1 with exactly 4 `FAIL` lines, the four `turns_passed` checks, each `expected '150', got '80'` or `expected '7', got '80'`. The refused limit checks already pass (Task 1).

- [ ] **Step 4: Point both drivers at the setting**

In `scripts/daily-ingest.sh`, inside `start_worker()` (claude branch), replace

```zsh
      --max-turns 80 \
```

with

```zsh
      --max-turns "$A5N_MAX_TURNS" \
```

Make the same replacement in `scripts/weekly-lint.sh`. Nothing else in either driver changes; the codex branch stays as it is.

- [ ] **Step 5: Run the scenario and see it pass**

Run: `zsh tests/sync-e2e.sh max_turns`
Expected: exit 0, `<n> passed, 0 failed`.

- [ ] **Step 6: The repository's checks**

Run each, from `/home/arda/A5N-wt-max-turns`:

```bash
python3 -m py_compile scripts/*.py
```

```bash
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do zsh -n "$f" || print -r -- "PARSE FAIL $f"; done
```

```bash
grep -rn -- '--max-turns' scripts
```

Expected: two lines, both `--max-turns "$A5N_MAX_TURNS"`, no number.

```bash
python3 - <<'EOF'
import pathlib, subprocess
names = subprocess.run(["git", "diff", "--name-only", "main"],
                       capture_output=True, text=True).stdout.split()
for name in names:
    text = pathlib.Path(name).read_text(encoding="utf-8")
    for n, line in enumerate(text.splitlines(), 1):
        if chr(0x2014) in line or chr(0x2013) in line:
            print(f"{name}:{n}: dash")
print("dash scan done")
EOF
```

Expected: only `dash scan done`.

```bash
zsh tests/sync-e2e.sh
```

Expected: the whole suite, a few minutes, last line `<n> passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
cd /home/arda/A5N-wt-max-turns
git branch --show-current   # must print feat/max-turns-setting
git add scripts/daily-ingest.sh scripts/weekly-lint.sh tests/fake-runner.sh tests/sync-e2e.sh
git commit -F - <<'EOF'
feat: both drivers take the worker's turn limit from config.ini

daily-ingest.sh and weekly-lint.sh passed --max-turns 80 to every
claude worker. They pass $A5N_MAX_TURNS now, which config.py exports
from limits.max_turns, 150 unless config.ini says otherwise. The codex
branch is unchanged: codex exec has no turn limit.

The fake runner writes the arguments it was given to runner.log.
max_turns checks that the ingest and the lint workers get 150 with no
max_turns line and 7 with max_turns = 7, and that max_turns = 0 stops
both drivers before any worker starts.

Co-Authored-By: Claude <your model name> <noreply@anthropic.com>
EOF
```

---

## After the tasks (the orchestrator, not the implementer)

- Review the diff against this plan and the Review Focus.
- Rerun every check of Task 2 Step 6 independently, and `A5N_BASELINE_REF=30d4d7a zsh tests/sync-e2e.sh sync_off_identical`.
- Revert copies: a driver with the literal 80 back must fail `max_turns`; config.py without `_validate_limits` must fail `config_validation`.
- One real run: a scratch config and a throwaway vault, the real claude CLI with a cheap model and `max_turns = 2`, `daily-ingest.sh` by hand. The log must show `Error: Reached max turns (2)` and the unit rolled back.
- Push the branch and open the pull request; the user merges.
