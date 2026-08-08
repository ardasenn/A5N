# Contributing to A5N

Contributions are welcome, especially adapters for new agent transcript
formats and fixes proven against a scratch vault.

## Ground rules

The repository's working rules live in [AGENTS.md](AGENTS.md) and apply to
humans too. The short version:

- **One place per setting.** Everything configurable reads from
  `config.ini` through `scripts/config.py`. Nothing else may hardcode it.
- **Orchestration is deterministic script; the model only works at the
  leaf.** If your change gives discovery, dedup, state keeping or
  verification to a model, it will be declined: every one of those moves
  has already produced a real failure here.
- **Prompts stay in English.** The vault language is injected at runtime.
- **The schema template is bilingual.** Change `template/SCHEMA.en.md` and
  `template/SCHEMA.tr.md` in the same commit.
- **Comments explain why**, ideally which failure a safety piece prevents.
  Do not delete those comments: they are the project's memory of what went
  wrong before.
- **No em dashes in prose.** Commas, colons and parentheses do the job.

## Testing a change

There is no test suite yet. Before opening a PR:

```bash
python3 -m py_compile scripts/*.py
zsh -n scripts/*.sh
```

Then point a scratch config at a throwaway vault and exercise what you
changed for real:

```bash
cp config.example.ini /tmp/a5n-test.ini   # edit: vault under /tmp
A5N_CONFIG=/tmp/a5n-test.ini zsh scripts/setup.sh
A5N_CONFIG=/tmp/a5n-test.ini zsh scripts/daily-ingest.sh
```

`A5N_MAX_UNITS`, `A5N_UNIT_TIMEOUT`, `A5N_BACKFILL=yes|no` and
`A5N_NO_NOTIFY` keep test runs small, fast and quiet. Never test against a
vault that holds real work.

## Adding a transcript format

The most useful contribution. Three touch points, all in `scripts/`:

1. `import-transcript.py`: format detection from the first line, plus a
   `should_drop_<format>` filter that removes ONLY zero information
   records. Adding a record type to a filter list is a schema change:
   prove the record carries nothing first.
2. `condense-transcript.py`: how a line of that format becomes
   `(role, body)` in the readable skeleton.
3. `ingest-discover.py`: where the files live and how a session maps to a
   project (folder name, embedded cwd, or whatever the format offers).

Cursor is the known hard case: chat history in an undocumented SQLite
schema that shifts between releases. If you can make an adapter that fails
loudly instead of rotting silently, we want it.

## Pull requests

- Keep one PR to one concern.
- Describe which failure mode your change prevents or which behavior it
  changes, not just what the diff does.
- If you changed anything under `scripts/`, paste the scratch vault
  evidence (the log lines or the commit list) into the PR description.
