# Read path, backfill and monthly digest

Date: 2026-08-07. Approved by the user in conversation. Three independent
features closing the three product gaps identified the same day: agents do
not read the vault, the first value moment comes too late, and accumulated
value is invisible.

## 1. MCP server, `scripts/a5n-mcp.py`

Pure Python 3.9, standard library only, stdio JSON-RPC 2.0 with
newline delimited messages. Read only. Reads the vault path through
`config.load()` and refuses to start without a config, like every other
entry point.

Protocol surface: `initialize`, `notifications/initialized` (ignored),
`ping`, `tools/list`, `tools/call`. Unknown methods return -32601.
Notifications never get a response. stdout carries only protocol JSON,
diagnostics go to stderr.

Tools:

* `vault_overview()`: root index.md, namespace list with per category page
  counts, pattern page list. The orientation call an agent makes first.
* `vault_search(query, project?, limit?)`: case insensitive term search over
  vault pages. Score: term frequency, title and tags bonus, recency bonus
  from the `date:` field. Returns path, title, status and up to three
  matching line excerpts per page. `raw/` is never scanned. `limit`
  defaults to 10, capped at 25.
* `vault_page(path)`: full page content. The path must resolve inside the
  vault, must end in `.md`, and `raw/` is refused. Content above 100 KB is
  truncated with a note.

Synthesis costs nothing: the calling agent is already a model, A5N only
returns data. Registration commands are printed by `setup.sh` and
documented in the README: `claude mcp add --scope user a5n -- python3
<repo>/scripts/a5n-mcp.py`, plus the Codex equivalent.

## 2. Backfill, interactive step at the end of `setup.sh`

After everything else, setup counts pending work deterministically: dry run
capture (`copied=N` from the summary) plus the queue length with the unit
cap lifted. If the total is positive and stdin is a TTY, ask: "N sessions
are waiting, one model run each. Process them now? [y/N]". Yes runs
`daily-ingest.sh` immediately with `A5N_MAX_UNITS` lifted. The
`A5N_BACKFILL=yes|no` environment variable overrides the question, which
also keeps automation and tests non interactive. A closing note explains
that the watermark controls how far back history reaches.

## 3. Monthly digest, `scripts/digest.py` plus `scripts/digest.sh`

Deterministic Python, no LLM, so the digest is free and cannot
hallucinate. Default period is the previous calendar month; an explicit
`YYYY-MM` argument overrides it.

Data, all from the vault itself: ingest commits in the period (sessions per
project), pages added and modified per category via `git log
--diff-filter`, new pattern pages, skip lines from the project logs, and
the five most wikilinked pages. A quiet month still produces a digest: "0
sessions" is a health signal, not noise.

Output: `<vault>/digests/YYYY-MM.md` with the standard frontmatter shape,
committed by the driver, plus a macOS notification on success. Headings
come from a tiny en/tr string table chosen by the vault language, falling
back to English: a deterministic script cannot translate and does not
pretend to.

Driver: shared `.lock` with ingest and lint, log under `.a5n-logs/`,
notification on failure too. Scheduling: new `[schedule]` key `digest = 1
09:37` (day of month plus time); `setup.sh` learns day of month calendar
keys and installs `com.a5n.digest`.

Schema and lint: `digests/` joins the root layout in both schema templates;
`lint-mech.py` and `fix-links.py` skip it (generated meta pages must not
show up as orphans).

## Order and verification

MCP server, then backfill, then digest. One commit each. Every feature is
exercised against the scratch vault smoke setup before its commit: the MCP
server with piped protocol messages, the backfill with `A5N_BACKFILL` in
both answers, the digest against the smoke vault's real git history.
