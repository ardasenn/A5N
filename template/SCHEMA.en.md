# {{VAULT_TITLE}}

This file is the schema. Every agent that touches this vault reads it first
and follows it exactly.

## Purpose

One vault, one namespace per project. A namespace is that project's permanent
knowledge archive: chat sessions, decisions, bugs and architecture notes pile
up over time and turn into a searchable wiki.

Language: every page is written in {{LANGUAGE}}. Technical terms may stay in
their original form.

## Namespace rule

Each project lives isolated in its own top level folder. A page for one
project is never written into another project's folder. Overlap at the code
level is normal to have none, since the stacks differ, and that is fine.

What does cross projects is not code but method. How you cut a release, how
you approach a bug, which class of mistake to avoid. Those go in the root
`patterns/` folder, see the cross project rule below.

## Root files

```
vault/
├── CLAUDE.md    this file, one schema for every project
├── AGENTS.md    pointer to CLAUDE.md so non Claude agents read the same rules
├── index.md     THIN, project list plus shared patterns
├── log.md       THIN, vault level events only (new project, schema change)
├── GOALS.md     always current snapshot of your goals, see below
├── patterns/    cross project method pages, stack agnostic
├── chess-moves/ forward looking strategy sessions, dated, see below
├── digests/     monthly value digests, written by the scheduled digest job
└── <project>/   one namespace per project, each with its own index and log
```

## Chess moves rule

`chess-moves/YYYY-MM-DD-<slug>.md` holds the output of strategy sessions: your
goals, planned moves, priority arguments. It is the mirror image of the rest
of the vault. The wiki looks backwards and records evidence, chess moves look
forwards and record intent.

* Written only with you, on an explicit request. The scheduled ingest never
  writes here.
* Old session files are never edited. A new one is written instead, so dated
  snapshots keep the evolution of your thinking visible.
* Readable during a query. When the question is whether some work serves the
  goal, the most recent chess moves file is the context.

## GOALS.md rule

`GOALS.md` is the always current, single file summary of your goals and where
things stand. Chess moves are the negotiation, GOALS.md is the outcome, so
updating it at the end of a chess moves session is the natural flow. Written
only from what you state. The scheduled jobs never touch it.

Root `index.md` and `log.md` stay short no matter how many projects you have.
Detail lives in `<project>/index.md` and `<project>/log.md`.

## Cross project pattern rule

For every decision or bug written during an ingest, ask: would this lesson
hold in another project, is it a method or a principle independent of the
stack?

* If yes, write `patterns/<slug>.md` or update the existing page. Say what the
  lesson is, which concrete event in which project produced it, and the
  general rule. Link to it from both projects and add it to the shared
  patterns section of the root `index.md`.
* If no, meaning it is specific to this code or stack, the project local page
  is enough.

During a query: if the question is about method or process rather than a
specific stack, look at root `patterns/` first, then go down into the
project's own pages. If the question is specific to one project, start from
that project's `index.md`.

## Folder layout, identical for every project

```
<project>/
├── raw/
│   ├── sessions/   agent transcripts (JSONL), READ ONLY
│   └── docs/       static documents, PDFs, design notes, READ ONLY
├── sources/
│   └── sessions/   one summary page per raw source
├── entities/       files, functions, services, screens, features, people
├── concepts/       abstract ideas ("matching algorithm", "onboarding flow")
├── decisions/      atomic decisions, one decision is one page
├── bugs/           fixed problems: root cause plus fix
├── syntheses/      high level overviews (architecture, roadmap summary)
└── archive/        outdated pages, never deleted
```

## Page format

YAML frontmatter, an H1 title, the content, then `## Sources` and `## Related`.

```yaml
---
title: <title>
tags: [<project>, <category>, ...]
source: <raw/... path, or "manual">
date: YYYY-MM-DD
status: active | stale | archived
state: open | pending | fixed | closed   # bugs/ pages ONLY
---
```

This shape is the same for every kind of page, `patterns/` and `chess-moves/`
included. No other frontmatter shape belongs in a vault page. In particular
the `name` / `description` / `metadata` shape belongs to an agent's own memory
files and must not leak in here.

### Enum rule, the lists are closed

The value lists for `status` and `state` are closed. Inventing a new value is
forbidden, even an obvious synonym such as `resolved`, `done`, `pr-open` or
`in review`. When a situation does not fit a listed value exactly, pick the
closest one and write the nuance as prose under a `## Status` heading in the
body. Never force the frontmatter.

* `status` is about the PAGE, on every kind of page:
  * `active`, the page is current and correct
  * `stale`, the content is out of date and needs a pass
  * `archived`, moved under `archive/`
* `state` is about the BUG itself, only on `bugs/` pages:
  * `open`, the problem stands and there is no fix (the default when unsure)
  * `pending`, a fix exists but is not live (PR open, in review, merged but
    not deployed, waiting on a data backfill)
  * `fixed`, the fix is live and verified
  * `closed`, closed without a fix (duplicate, wontfix, invalid)

A bug page stays `status: active` even after the bug is fixed, because the
page is still correct. The two fields are orthogonal and never substitute for
each other.

Why the rule is written down: a first bulk ingest once produced eight
different `status` values across eighty eight bug pages, with `fixed` and
`resolved` both present, because the schema had never been written anywhere
and every run invented its own vocabulary.

### Link rule

A link, `[[wikilink]]` or `[text](path)`, points only at a page inside the
vault. Code paths and symbol names are written as plain backticked text, not
as links:

* right: `` `apps/backend/.../ListingRepository.cs:142` ``
* wrong: `[ListingRepository.cs:142](apps/backend/.../ListingRepository.cs:142)`
* wrong: `[[apps/backend/.../ListingRepository.cs:142]]`

External URLs may be ordinary markdown links. The rule is about repository
code paths.

Reason: any link whose target is not in the vault is a dead link, and the
weekly lint reports them all.

## Naming

kebab-case filenames. `sources/sessions/YYYY-MM-DD-<slug>.md`.

## INGEST workflow, two layers

Daily and unattended: `scripts/daily-ingest.sh`. The principle: ORCHESTRATION
IS DETERMINISTIC SCRIPT, THE MODEL ONLY WORKS AT THE LEAF ("read and write");
success is measured by the ARTIFACT, never by a claim; units are committed
independently. (The previous design, one model run doing discovery, copying,
pages and a result signature with a wholesale rollback on failure, produced a
new choreography failure every week and once deleted a finished day's work.)

**Layer 1, capture (pure script, no LLM).** `ingest-discover.py capture`
scans both transcript sources from `config.ini` (the single authority for
discovery), applies the watermark, freshness, size and duplicate content
filters, and copies survivors through the `import-transcript.py` filter into
`<project>/raw/sessions/`. Never a symlink: agents delete old transcripts
after a while, Claude Code after `cleanupPeriodDays` which defaults to about
thirty days, and the vault keeps its own permanent copy. This is the only
time critical work. The `source:` frontmatter of every page points at this in
vault path.

Two agent formats are supported and detected from the first line:
* **Claude Code**, `<claude_projects>/<folder>/<uuid>.jsonl`, target name
  `<uuid>.jsonl`, matched by folder name. The filter drops
  `attachment/hook_success`, roughly 64 percent of the file and zero
  information, the same data is already there as `tool_result`/`tool_use`.
* **Codex**, `<codex_sessions>/YYYY/MM/DD/rollout-*.jsonl`, target name
  `codex-<session_id>.jsonl`, matched by the session's own working
  directory. The filter drops only `event_msg/token_count` telemetry.

Duplicates are judged by CONTENT, not filename (the first surviving line):
candidate contained in an existing raw, not copied; candidate larger, copied
under its new id and the old file kept. Small and duplicate drops get a
DETERMINISTIC skip line in `<project>/log.md`, "never skip in silence" is a
script guarantee now. The result is one commit: `chore: raw capture`.

State is not kept in a separate file, THE VAULT ITSELF IS THE STATE:
- captured = `<project>/raw/sessions/<id>.jsonl` exists
- processed = a TRACE exists, and only two shapes count: a sources page
  containing the full raw path `raw/sessions/<id>.jsonl`, or a
  `skip | <id>` line in `<project>/log.md`. A bare id mentioned in prose
  is NOT a trace, so a note can never silently dequeue a session. A raw
  with no trace is queued.

**Layer 2, processing (one model worker per session).** `ingest-discover.py
queue` lists the unprocessed raws (oldest first, per run cap in config); the
driver runs a SEPARATE, synchronous headless worker for each one
(`scripts/prompts/ingest-unit.md`; subagents, scheduling and background work
disallowed, a wall clock per unit; transcripts above the condense threshold
are reduced to a skeleton first). When a unit finishes, `ingest-verify.py`
checks the ARTIFACT mechanically: are the changes on in schema paths, does
the id trace exist (page or skip line), is the frontmatter complete. Pass:
the unit is committed IMMEDIATELY (`chore: ingest(<project>) <id>`). Fail:
only THAT unit is rolled back, it stays queued and retries tomorrow by
itself. On an empty day the model is never invoked. Silence is success, a
notification only fires on failure.

**Worker steps** (the unit prompt points here; the same flow applies when
you are asked by hand to "process this session"):

1. Read the session, pull out the main subject.
2. Write `<project>/sources/sessions/YYYY-MM-DD-<slug>.md` (date = the
   session's own date): goal, what was done, files changed, decisions,
   problems, open questions.
3. Create or cross update every entity, concept, decision and bug page it
   mentions, with links in both directions; if the session changes the STATE
   of an existing page (a bug fixed, a decision overturned), update that
   page too.
4. Apply the cross project pattern rule above.
5. Update `<project>/index.md`.
6. Append `## [YYYY-MM-DD] ingest | <slug>` to `<project>/log.md`.

## QUERY workflow

1. If the question is specific to one project, start from
   `<project>/index.md`. If it is about method or process, look at root
   `patterns/` first.
2. Go down into the relevant pages under `sources/`, `entities/`,
   `concepts/`, `decisions/` and `syntheses/`.
3. Every claim in the answer carries a source reference.
4. If the answer produced a synthesis or comparison worth keeping, file it
   back as an atomic page under `<project>/syntheses/`, or under `patterns/`
   when it concerns more than one project.
5. Append `## [YYYY-MM-DD] query | <question summary>` to `<project>/log.md`.

## LINT workflow

Weekly and unattended, `scripts/weekly-lint.sh`, two layers.

1. **Mechanical, deterministic.** `scripts/fix-links.py` repairs wrong path
   links automatically, the only automatic edit in the system.
   `scripts/lint-mech.py` scans for dead links and orphans. The namespace
   list is dynamic, every root directory holding a `sources/` folder, so a
   new project is covered automatically.
2. **Semantic, report only, one worker per project.** Contradictions,
   missing cross references, concepts with no page, frontmatter drift, wrong
   link targets. `<project>/lint-report.md` is overwritten (the old report
   stays in git history), one line goes to `<project>/log.md`. Verification
   is mechanical, only those two files may change, so a failing project
   cannot take the others down. Semantic findings are never auto fixed. You
   decide what to change.

## Adding a project

1. Add a `[project:<name>]` section to `config.ini`.
2. Run `scripts/setup.sh` again. The namespace skeleton, its `index.md` and
   its `log.md` are created for you.
3. Add one line to the projects list in the root `index.md`.
4. Two touches in the project repository itself: an "A5N knowledge vault"
   section in its `CLAUDE.md` or `AGENTS.md` pointing at the namespace, and
   the vault path in `permissions.additionalDirectories` in its
   `.claude/settings.local.json` so an agent working there can read it.
5. Append `## [YYYY-MM-DD] setup | <project> namespace opened` to the root
   `log.md`.

## Hard rules

1. `raw/` is never modified, only read. The single exception is the INGEST
   capture layer, which adds new files and never touches existing ones; a
   layer 2 worker writing under `raw/` is rejected by verification.
   Filtering drops only zero information records, so raw fidelity holds.
   Adding a new record type to the filter list is a SCHEMA CHANGE: first prove
   the record carries no information, then update that line. Deleting a
   redundant raw file, a second copy of the same conversation, is your call.
   The scheduled jobs never delete a raw file on their own.
2. No claim without a source. Every meaningful sentence says which raw or
   source file it rests on.
3. Pages are never deleted, they move to `archive/`.
4. Contradictions are marked with a `## CONFLICT` heading, never removed.
5. A project never writes into another project's folder.
6. The schema evolves. When a rule does not work, this file gets updated.
