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

Every morning a deterministic script finds yesterday's sessions and copies the
raw transcripts somewhere permanent. Then one headless agent per session
distils it into a linked markdown wiki: one page per session, plus pages for
the decisions, bugs, entities and concepts it touches. Once a week the same
machinery audits that wiki for contradictions, dead links and schema drift.

The output is plain markdown in a git repository. Obsidian is a nice way to
browse it and is entirely optional. Nothing is stored anywhere but your disk.

![How A5N works](assets/architecture.svg)

The most valuable folder is `patterns/`. When a lesson is not tied to one
project, it gets its own page there, and your next project finds it. That is
what turns a pile of notes into knowledge that keeps growing in value.

See [example/](example/) for four pages of invented output, and
[the pattern page](example/patterns-example/retry-without-a-budget-amplifies-an-outage.md)
for what the system is actually for.

## Install

Requires macOS or Linux, Python 3.9 or newer, git, and either the Claude Code
CLI or the Codex CLI for the unattended runs. You pick which one runs the
workers, with which model and at what reasoning effort, in the `[runner]`
section of `config.ini`. The example config lists the valid values ready to
copy, so a typo cannot break a scheduled run.

```bash
git clone https://github.com/ardasenn/A5N.git
cd A5N
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

## Reading it back

Writing pages is only half the job: your agents also need to read them. A5N
ships an MCP server that gives any MCP capable agent read access to the vault,
with search, an overview, and full page reads. Register it once per machine
and every agent session can check the vault before repeating your history:

```bash
claude mcp add --scope user a5n -- python3 "$(pwd)/scripts/a5n-mcp.py"
```

```toml
# Codex, in ~/.codex/config.toml
[mcp_servers.a5n]
command = "python3"
args = ["/path/to/A5N/scripts/a5n-mcp.py"]
```

The server is read only and never opens `raw/`. It does its own ranking, so
a query adds no model cost. `setup.sh` prints these commands with the real
paths filled in.

Registering the server makes the vault reachable. It does not make agents
look, because an available tool is not a used tool: without a standing
instruction, agents answer history questions from guesswork instead of the
archive. Add a block like this to each project's CLAUDE.md or AGENTS.md:

```markdown
## Knowledge vault (A5N)

This project has a permanent knowledge archive: decisions, bug root causes
and architecture notes distilled from earlier agent sessions.

- When you need history, an old bug or the reason behind a decision, ask
  the a5n MCP server first: `vault_overview` for the catalogue,
  `vault_search` for anything specific.
- For methods and lessons that span projects, search the pattern pages.
- The vault is read only from here. Writing is done by the vault's own
  automation, never from this repository.
```

## Seeing what accumulates

Once a month a plain script (no model involved) turns the vault's git history
into one page under `digests/`: sessions processed per project, pages created
and updated, new patterns, the most referenced pages, and a health line. If a
whole month went by with nothing processed, the digest says so, because
without that line you cannot tell a broken pipeline from a quiet month.

```bash
zsh scripts/digest.sh            # previous month
zsh scripts/digest.sh 2026-07    # any month
```

At setup time, if sessions are already waiting, A5N offers to process them
right away, so you see your first pages within minutes instead of waiting for
tomorrow's schedule. The `watermark` in `config.ini` controls how far back
that history reaches.

## How it holds together

Unattended jobs fail quietly unless you design against it. A5N's answer is
one principle: scripts run the pipeline, the model only reads sessions and
writes pages.

- **Finding sessions never involves a model.** A Python script scans the
  transcript folders, filters the candidates, drops duplicates, and copies the
  rest into the vault. This part cannot hallucinate, and it is the only urgent
  part: agents delete old transcripts, so the copy must happen in time.
- **One worker per session, judged by its files.** Each queued session gets
  its own headless agent run. When it ends, a script looks at what actually
  landed on disk: are the changed paths allowed, did a page or a reasoned
  skip line appear, is the frontmatter complete. What the worker says about
  its own work is never trusted. An earlier design trusted a result line in
  the output, and a single stray backtick once threw away twelve processed
  sessions.
- **Each session commits on its own.** A unit that passes is committed on the
  spot. A unit that fails is rolled back alone and retried tomorrow; the other
  units' work is already safe. There is no bookkeeping file: a raw transcript
  that has no trace in the pages is still in the queue, by definition.
- **A rejected unit gets one more chance.** The rejection reasons are added
  to the prompt and the worker runs once more, so a small mistake is fixed
  within the same run instead of repeating for days.
- The vault is a git repository and the tree is always clean before a worker
  starts, so a rollback can only ever touch that one worker's output.
- One lock file is shared by every job, ingest, lint and digest, so none can
  overlap another. A lock older than two hours is treated as dead, because a
  crash cannot run the cleanup trap and a stale lock would silently swallow
  every later run.
- A watchdog kills a worker that exceeds its per unit wall clock. Not a work
  limit, only a guard against hanging forever.
- Skipping is never silent. When a session is dropped for being too small or
  a duplicate, the script itself writes a line saying so in the project log.
  Two cases write no line on purpose: sessions older than your configured
  watermark, and sessions still in use, which simply wait for tomorrow.
- On a day with nothing to do, the model is never invoked. Silence is success,
  a notification fires only on failure.

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
