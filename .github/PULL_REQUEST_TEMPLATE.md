**What this changes and which failure it prevents**

**Checklist**

- [ ] `python3 -m py_compile scripts/*.py` and `zsh -n scripts/*.sh` pass
- [ ] Exercised against a scratch vault (evidence below), never a real one
- [ ] If the schema changed: `SCHEMA.en.md` and `SCHEMA.tr.md` updated in
      this same PR
- [ ] New settings live in `config.ini` via `scripts/config.py`, nowhere
      else
- [ ] Comments say why (which failure), not what

**Scratch vault evidence**

```
(log lines or commit list from the throwaway vault run)
```
