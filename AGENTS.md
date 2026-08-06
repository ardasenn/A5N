# Working on A5N

This repository is the tool. A vault is the data it produces. Never confuse
the two: nothing here should contain anyone's real notes, transcripts or
project names.

## Layout

```
config.example.ini   every setting, copied to config.ini by the user
scripts/config.py    the only place that reads config.ini
scripts/*.sh         the unattended runs
scripts/*.py         transcript handling and mechanical lint
scripts/prompts/     what the headless agent is told, English only
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

There is no test suite yet. At minimum, before committing:

```bash
python3 -m py_compile scripts/*.py
zsh -n scripts/*.sh
python3 scripts/config.py --check      # against a scratch config.ini
```

For a real end to end run, point a scratch config at a throwaway vault path
and run the ingest by hand. Never test against a vault that holds real work.
