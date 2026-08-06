# A5N

Turn your AI coding agent transcripts into a knowledge base that outlives them.

[Türkçe](README.tr.md)

## The problem

Claude Code and Codex write every session to disk, then delete it. Claude Code
clears transcripts after `cleanupPeriodDays`, thirty days by default. So the
reasoning behind a decision you made six weeks ago, the root cause of a bug you
already fixed once, the reason you rejected the obvious approach, all of it is
gone. You keep solving the same problem, and your agent keeps proposing the
approach you already rejected, because neither of you can remember.

## What A5N does

Every morning it finds yesterday's sessions, copies the raw transcripts
somewhere permanent, and distils them into a linked markdown wiki: one page per
session, plus pages for the decisions, bugs, entities and concepts they touch.
Once a week it audits that wiki for contradictions, dead links and schema drift.

The output is plain markdown in a git repository. Obsidian is a nice way to
browse it and is entirely optional. Nothing is stored anywhere but your disk.

The part that pays for the whole thing is `patterns/`. When a lesson holds
beyond the project that produced it, it gets its own page, and the next project
finds it. That is the difference between a pile of notes and something that
compounds.

See [example/](example/) for four pages of invented output, and
[the pattern page](example/patterns-example/retry-without-a-budget-amplifies-an-outage.md)
for what the system is actually for.

## Install

Requires macOS or Linux, Python 3.9 or newer, git, and the Claude Code CLI for
the unattended runs.

```bash
git clone https://github.com/<you>/a5n.git
cd a5n
cp config.example.ini config.ini
$EDITOR config.ini
zsh scripts/setup.sh
```

`setup.sh` creates the vault, writes the schema into it, adds a namespace per
configured project, initialises git, and installs the scheduled jobs. Run it
again any time: existing pages are never overwritten, so rerunning is how you
add a project or change the schedule.

Nothing runs until `config.ini` exists. A fresh checkout cannot touch a vault
by accident.

## Configuration

One file, `config.ini`. Adding a project is one section:

```ini
[project:acme-shop]
repo = ~/work/acme-shop
match = acme-shop
watermark = 2026-01-01
```

`match` is a substring. It is checked against the Claude Code project folder
name and against the Codex session working directory, so one value usually
covers both, and git worktrees match automatically because their paths contain
it too.

`watermark` is a fixed date, not a rolling window. Sessions older than it are
ignored. Set it to today to start clean, or to an older date to pull in
history. Because it is fixed rather than rolling, a machine that was off for a
week loses nothing when it comes back.

See [config.example.ini](config.example.ini) for every setting.

## Running it

```bash
zsh scripts/daily-ingest.sh    # what the scheduler runs each morning
zsh scripts/weekly-lint.sh     # what it runs weekly
```

Both are safe to run by hand at any time. They take a lock, so a manual run and
a scheduled one cannot collide.

## How it holds together

Unattended jobs fail quietly unless you design against it, so:

- The agent must end its output with a signature line. No signature means the
  agent never really ran, the run counts as failed, nothing is committed and a
  notification fires.
- The vault is a git repository and the tree is always clean before a run
  starts. Anything dirty afterwards is agent output, so a failed run is undone
  with `reset --hard` and half finished work never reaches a commit.
- A lock file prevents overlap. A lock older than two hours is treated as dead,
  because a crash cannot run the cleanup trap and a stale lock would silently
  swallow every later run.
- A watchdog kills a run that exceeds the wall clock. Not a work limit, only a
  guard against hanging forever.
- Skipping is never silent. A session that could not be processed gets a line
  in the project log saying so.

Each of those exists because the missing version of it caused a real failure.

## Transcript formats

| | Claude Code | Codex |
|---|---|---|
| Location | `~/.claude/projects/<folder>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Project matched by | folder name | the session's own working directory |
| Filtered out on copy | `attachment/hook_success`, about 64% | `event_msg/token_count`, about 1.4% |

Both filters drop only records that carry no information at all. Everything
else is copied byte for byte, images included. Adding a record type to a
filter list is a schema change: prove it carries nothing first.

Large transcripts are condensed before reading. Size comes from embedded
screenshots rather than content, so dropping those has taken a 107 MB session
down to 404 KB with the conversation intact.

Cursor is not supported. It keeps chat history in a SQLite file with an
undocumented schema that changes between releases, so an adapter would break
often. Pull requests welcome if you disagree.

## Licence

MIT. See [LICENSE](LICENSE).
