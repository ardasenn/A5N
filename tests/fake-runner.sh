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
#   FAKE_RUNNER_SLEEP    write half a page (a lint worker writes nothing),
#                        then sleep this many seconds, so a test can kill
#                        the driver mid unit
#   FAKE_RUNNER_PIDFILE  where to write this process's pid before sleeping
#   FAKE_RUNNER_SHARED   text for line 3 of the root index.md: the shape of
#                        an edit two machines can both make
#
# Every run writes a start and an end line, with its pid and working
# directory, to $A5N_TEST_CALLS/workers.log: that is how a test sees two
# workers running in one vault at the same time. It also writes every
# argument after the prompt, one line per run, to
# $A5N_TEST_CALLS/runner.log: that is how a test sees what the driver
# passed, the turn limit among them.
set -u
# Stopped with TERM, the runner takes its sleep along: a sleep left in the
# driver's session would hide the leaks t_stopped_run looks for.
trap 'kill $! 2>/dev/null; exit 143' TERM
trace() { [ -n "${A5N_TEST_CALLS:-}" ] && print -r -- "$1 $$ $PWD" >> "$A5N_TEST_CALLS/workers.log"; }
trace start
trap 'trace end' EXIT
[ -n "${A5N_TEST_CALLS:-}" ] && print -r -- "${*:3}" >> "$A5N_TEST_CALLS/runner.log"

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
  if [ -n "${FAKE_RUNNER_SLEEP:-}" ]; then
    [ -n "${FAKE_RUNNER_PIDFILE:-}" ] && print -r -- $$ > "$FAKE_RUNNER_PIDFILE"
    sleep "$FAKE_RUNNER_SLEEP" & wait $!
  fi
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
  sleep "$FAKE_RUNNER_SLEEP" & wait $!
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
