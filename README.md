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

The part that pays for the whole thing is `patterns/`. When a lesson holds
beyond the project that produced it, it gets its own page, and the next project
finds it. That is the difference between a pile of notes and something that
compounds.

See [example/](example/) for four pages of invented output, and
[the pattern page](example/patterns-example/retry-without-a-budget-amplifies-an-outage.md)
for what the system is actually for.

## Install

Requires macOS or Linux, Python 3.9 or newer, git, and one of the Claude Code
CLI or the Codex CLI for the unattended runs. Which one drives the workers,
which model it uses and at what reasoning effort are all picked in the
`[runner]` section of `config.ini`, and the example config carries copy paste
value lists so a typo cannot reach a scheduled run.

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

The vault is only worth what gets read out of it, so A5N ships an MCP server
that gives any MCP capable agent read access: ranked search over the pages, a
vault overview, and full page reads. Register it once per machine and every
agent session can consult the vault before repeating your history:

```bash
claude mcp add --scope user a5n -- python3 "$(pwd)/scripts/a5n-mcp.py"
```

```toml
# Codex, in ~/.codex/config.toml
[mcp_servers.a5n]
command = "python3"
args = ["/path/to/A5N/scripts/a5n-mcp.py"]
```

The server is read only, never opens `raw/`, and does its own ranking, so a
query costs nothing beyond what the calling agent was already spending.
`setup.sh` prints these commands with the real paths filled in.

## Seeing what accumulates

Once a month a deterministic script, no model involved, turns the vault's git
history into one page under `digests/`: sessions processed per project, pages
created and updated, new patterns, the most referenced pages, and a health
line that says out loud when a month went by with nothing processed. That last
one matters: a pipeline that fails in silence looks identical to a quiet
month until something makes the difference visible.

```bash
zsh scripts/digest.sh            # previous month
zsh scripts/digest.sh 2026-07    # any month
```

At setup time, if sessions are already waiting, A5N offers to process the
backlog immediately instead of leaving the first value moment to tomorrow's
schedule. The `watermark` in `config.ini` controls how far back that history
reaches.

## How it holds together

Unattended jobs fail quietly unless you design against it. The architecture
answers that with one principle: orchestration is deterministic script, the
model only works at the leaf.

- **Discovery never involves a model.** A Python script scans the transcript
  folders, filters and dedups candidates, and copies survivors into the vault.
  This is the only time critical work, since agents delete transcripts after a
  while, and none of it can hallucinate.
- **One worker per session, verified by its artifact.** Each queued session
  gets its own headless agent run. When it ends, a script inspects what was
  actually written to disk: are the changed paths inside the schema, did a
  page or a reasoned skip line appear, is the frontmatter complete. The
  worker's own words are never trusted. An earlier design grepped the output
  for a result signature, and one backtick around it once voided twelve
  processed sessions.
- **Units commit independently.** A unit that passes verification is committed
  on the spot. A unit that fails is rolled back alone, stays in the queue, and
  retries tomorrow; its siblings' work is already safe. The queue needs no
  bookkeeping file because the vault itself is the state: a raw transcript
  with no trace in the pages is, by definition, still queued.
- **A rejected unit gets one more chance.** The verification reasons are
  appended to the prompt and the worker runs again, so ordinary compliance
  variance closes within the run instead of the queue chewing on the same
  unit for days.
- The vault is a git repository and the tree is always clean before a worker
  starts, so a rollback can only ever touch that one worker's output.
- One lock file is shared by every job, ingest, lint and digest, so none can
  overlap another. A lock older than two hours is treated as dead, because a
  crash cannot run the cleanup trap and a stale lock would silently swallow
  every later run.
- A watchdog kills a worker that exceeds its per unit wall clock. Not a work
  limit, only a guard against hanging forever.
- Skipping is never silent. Every session dropped on its merits, too small or
  a duplicate, gets a deterministic line in the project log, written by the
  script rather than requested from the model. The two exceptions are
  deliberate: watermark drops are configured, and a too fresh session simply
  waits for tomorrow.
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
