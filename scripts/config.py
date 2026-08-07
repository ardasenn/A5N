#!/usr/bin/env python3
"""Single source of truth for A5N settings.

Everything configurable lives in config.ini next to this repository. Shell
scripts and Python scripts both read it through this module so a setting is
never defined in two places.

INI rather than TOML on purpose: macOS still ships Python 3.9 and tomllib
arrived in 3.11. Asking people to upgrade Python before they can try the tool
is a setup barrier, and configparser is in every Python 3.

Command line:
    python3 scripts/config.py --sh              shell exports, for eval
    python3 scripts/config.py --get vault.path  one value
    python3 scripts/config.py --projects        one project per line, TSV
    python3 scripts/config.py --check           validate, exit 1 on problems

As a module:
    from config import load, projects, repo_root
"""
import configparser
import os
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(os.environ.get("A5N_CONFIG") or REPO_ROOT / "config.ini")

DEFAULTS = {
    "vault": {"path": "", "language": "English", "title": "Knowledge Vault"},
    "agents": {
        "claude_projects": "",
        "codex_sessions": "",
        "claude_bin": "auto",
        "model": "claude-sonnet-5",
    },
    "schedule": {"enabled": "yes", "ingest": "09:07", "lint": "sun 11:07"},
    "limits": {
        "min_session_kb": "50",
        "settle_hours": "2",
        "unit_timeout": "1800",
        "max_units": "15",
        "condense_over_kb": "2048",
    },
}


class ConfigError(Exception):
    pass


def _expand(value):
    return str(Path(os.path.expanduser(value)).resolve()) if value else ""


def load(path=None):
    """Return settings as a nested dict. Raises ConfigError when unusable."""
    path = Path(path) if path else CONFIG_PATH
    if not path.is_file():
        raise ConfigError(
            f"config not found: {path}\n"
            f"Copy the example and edit it:\n"
            f"    cp {REPO_ROOT / 'config.example.ini'} {REPO_ROOT / 'config.ini'}"
        )
    parser = configparser.ConfigParser()
    parser.read(path, encoding="utf-8")

    cfg = {section: dict(values) for section, values in DEFAULTS.items()}
    for section in parser.sections():
        if section.startswith("project:"):
            continue
        cfg.setdefault(section, {}).update(dict(parser[section]))

    for key in ("path",):
        cfg["vault"][key] = _expand(cfg["vault"][key])
    for key in ("claude_projects", "codex_sessions"):
        cfg["agents"][key] = _expand(cfg["agents"][key])

    if not cfg["vault"]["path"]:
        raise ConfigError(f"vault.path is empty in {path}")

    binary = cfg["agents"]["claude_bin"]
    if binary == "auto":
        found = shutil.which("claude")
        if not found:
            raise ConfigError(
                "agents.claude_bin is 'auto' but no 'claude' was found on PATH.\n"
                "Install the CLI or set an explicit path in config.ini."
            )
        cfg["agents"]["claude_bin"] = found

    cfg["_projects"] = _projects(parser)
    cfg["_config_path"] = str(path)
    return cfg


def _projects(parser):
    out = []
    for section in parser.sections():
        if not section.startswith("project:"):
            continue
        name = section.split(":", 1)[1].strip()
        if not name:
            raise ConfigError(f"section [{section}] has no project name")
        values = parser[section]
        match = values.get("match", "").strip() or name
        out.append(
            {
                "name": name,
                "repo": os.path.expanduser(values.get("repo", "").strip()),
                "match": match,
                "watermark": values.get("watermark", "").strip(),
            }
        )
    return out


def projects(cfg=None):
    return (cfg or load())["_projects"]


def repo_root():
    return REPO_ROOT


def _shell_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def _emit_shell(cfg):
    flat = {
        "A5N_REPO": REPO_ROOT,
        "A5N_CONFIG_FILE": cfg["_config_path"],
        "A5N_VAULT": cfg["vault"]["path"],
        "A5N_LANGUAGE": cfg["vault"]["language"],
        "A5N_VAULT_TITLE": cfg["vault"]["title"],
        "A5N_CLAUDE_BIN": cfg["agents"]["claude_bin"],
        "A5N_MODEL": cfg["agents"]["model"],
        "A5N_CLAUDE_PROJECTS": cfg["agents"]["claude_projects"],
        "A5N_CODEX_SESSIONS": cfg["agents"]["codex_sessions"],
        "A5N_SCHEDULE_ENABLED": cfg["schedule"]["enabled"],
        "A5N_SCHEDULE_INGEST": cfg["schedule"]["ingest"],
        "A5N_SCHEDULE_LINT": cfg["schedule"]["lint"],
        "A5N_MIN_SESSION_KB": cfg["limits"]["min_session_kb"],
        "A5N_SETTLE_HOURS": cfg["limits"]["settle_hours"],
        "A5N_UNIT_TIMEOUT": cfg["limits"]["unit_timeout"],
        "A5N_MAX_UNITS": cfg["limits"]["max_units"],
        "A5N_CONDENSE_KB": cfg["limits"]["condense_over_kb"],
        "A5N_PROJECT_NAMES": " ".join(p["name"] for p in cfg["_projects"]),
    }
    for key, value in flat.items():
        print(f"export {key}={_shell_quote(value)}")


def _dotted(cfg, key):
    section, _, name = key.partition(".")
    if section not in cfg or name not in cfg[section]:
        raise ConfigError(f"unknown setting: {key}")
    return cfg[section][name]


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    try:
        cfg = load()
    except ConfigError as exc:
        sys.stderr.write(f"A5N config error:\n{exc}\n")
        return 1

    mode = argv[1]
    if mode == "--sh":
        _emit_shell(cfg)
    elif mode == "--get":
        if len(argv) < 3:
            sys.exit("--get needs a key, for example vault.path")
        try:
            print(_dotted(cfg, argv[2]))
        except ConfigError as exc:
            sys.stderr.write(f"{exc}\n")
            return 1
    elif mode == "--projects":
        for p in cfg["_projects"]:
            print(f"{p['name']}\t{p['match']}\t{p['watermark']}\t{p['repo']}")
    elif mode == "--check":
        if not cfg["_projects"]:
            sys.stderr.write(
                "No [project:...] section found. Add at least one so the "
                "ingest knows which transcripts belong to you.\n"
            )
            return 1
        print(f"config OK: {cfg['_config_path']}")
        print(f"vault: {cfg['vault']['path']} ({cfg['vault']['language']})")
        for p in cfg["_projects"]:
            print(f"project: {p['name']} (match '{p['match']}', since {p['watermark']})")
    else:
        sys.exit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
