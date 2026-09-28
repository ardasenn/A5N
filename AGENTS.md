# Working on A5N

This repository is the tool. A vault is the data it produces. Never confuse
the two: nothing here should contain anyone's real notes, transcripts or
project names.

## Layout

```
config.example.ini   every setting, copied to config.ini by the user
scripts/config.py    the only place that reads config.ini
scripts/*.sh         the unattended run drivers (deterministic orchestration)
scripts/ingest-*.py  discovery and capture, queue, artifact verification
scripts/*.py         transcript handling and mechanical lint
scripts/lib/         functions the drivers source: sync, notification, unit flag
scripts/prompts/     what one headless worker is told, English only
tests/               end to end tests, scratch directories only
template/            copied into a new vault by setup.sh
example/             invented sample output, referenced from the README
```

## Rules

**One place per setting.** If a value belongs in `config.ini`, nothing else
may hardcode it. Shell scripts read it through `config.py --sh`, Python
scripts import `config.load()`.

**Nothing runs without a config.** Every entry point must fail with a clear
message when `config.ini` is missing. A fresh checkout must not be able to
touch a real vault.

**Prompts stay in English.** The vault language is a config value that gets
injected at runtime. Keeping two translated copies of a prompt guarantees they
drift apart.

**The schema template is bilingual.** `template/SCHEMA.en.md` and
`template/SCHEMA.tr.md` are short enough to keep in sync by hand. Change one,
change the other in the same commit.

**Frontmatter keys are English in every language.** The lint checks those
values, and per language vocabularies would need per language checks.

**No em dashes in any prose.** Commas, colons and parentheses do the job.

**Comments explain why, not what.** The safety machinery in the shell scripts
looks paranoid until you know which failure produced each piece, so each one
says which failure it prevents. Do not strip those comments.

**Setup is idempotent.** `setup.sh` runs many times. Never overwrite a page a
user may have edited.

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

For a real end to end run, point a scratch config at a throwaway vault path
and run the ingest by hand. Never test against a vault that holds real work.
