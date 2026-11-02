#!/usr/bin/env python3
"""Tests for match_folders: collecting sessions started in a general folder.

The gap this closes: a conversation started without picking a project lands
in a general folder, the home folder on one machine and the desktop on another,
and match could not select those. The home folder's name starts every other
folder's name, so a substring would hit every project and stop the run. The
line has to mean the same thing on machines with different user names, so ~
expands where the file is read.

Everything happens in a temporary directory, with HOME pointing inside it: a
scratch config.ini (passed through A5N_CONFIG), a vault, a Claude projects
folder and a Codex sessions folder. No real vault or transcript is touched, no
model runs. Runs on macOS and Linux, needs only python3.

Usage: python3 tests/capture-folders.py
       A5N_KEEP_TEST_DIR=1 python3 tests/capture-folders.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISCOVER = os.path.join(REPO, "scripts", "ingest-discover.py")
CONFIG = os.path.join(REPO, "scripts", "config.py")

FAILS = []


def check(cond, what):
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        FAILS.append(what)


def folder_name(path):
    return re.sub(r"[^A-Za-z0-9-]", "-", path)


def sid(n):
    return f"{n:08x}-0000-0000-0000-000000000000"


class World:
    def __init__(self, root, user="alice"):
        self.root = root
        self.home = os.path.join(root, "users", user)
        self.vault = os.path.join(root, "vault")
        self.claude = os.path.join(root, "claude", "projects")
        self.codex = os.path.join(root, "codex", "sessions", "2026", "01", "02")
        self.config = os.path.join(root, "config.ini")
        os.makedirs(self.home)
        os.makedirs(self.claude)
        os.makedirs(self.codex)
        for ns in ("demo", "general"):
            os.makedirs(os.path.join(self.vault, ns, "raw", "sessions"))
            os.makedirs(os.path.join(self.vault, ns, "sources", "sessions"))
            with open(os.path.join(self.vault, ns, "log.md"), "w") as f:
                f.write(f"# {ns} log\n")

    def write_config(self, projects):
        with open(self.config, "w", encoding="utf-8") as f:
            f.write(f"""[vault]
path = {self.vault}
language = English
title = Test Vault
[agents]
claude_projects = {self.claude}
codex_sessions = {os.path.join(self.root, "codex", "sessions")}
[runner]
engine = claude
bin = auto
model = test
effort =
[schedule]
enabled = no
ingest = 09:07
lint = off
digest = off
[limits]
min_session_kb = 0
settle_hours = 0
unit_timeout = 60
max_turns = 10
max_units = 100
condense_over_kb = 2048
[sync]
enabled = no
remote = origin
branch = main
raw_remote =
lock = yes
offline_after = 900
{projects}
""")

    def env(self):
        return dict(os.environ, A5N_CONFIG=self.config, HOME=self.home)

    def capture(self):
        return subprocess.run([sys.executable, DISCOVER, "capture"],
                              env=self.env(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)

    def project_list(self):
        return subprocess.run([sys.executable, CONFIG, "--projects"],
                              env=self.env(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)

    def in_home(self, *parts):
        return os.path.join(self.home, *parts)

    def claude_session(self, path, session):
        d = os.path.join(self.claude, folder_name(path))
        os.makedirs(d, exist_ok=True)
        rec = {"type": "user", "sessionId": session,
               "timestamp": "2026-01-02T10:00:00.000Z",
               "message": {"role": "user", "content": f"hello from {session}"}}
        ans = {"type": "assistant", "sessionId": session,
               "timestamp": "2026-01-02T10:00:05.000Z",
               "message": {"role": "assistant", "content": f"reply {session}"}}
        with open(os.path.join(d, f"{session}.jsonl"), "w") as f:
            f.write(json.dumps(rec) + "\n" + json.dumps(ans) + "\n")

    def codex_session(self, session, cwd):
        meta = {"timestamp": "2026-01-02T10:00:00.000Z",
                "type": "session_meta",
                "payload": {"id": session, "cwd": cwd,
                            "timestamp": "2026-01-02T10:00:00.000Z"}}
        item = {"timestamp": "2026-01-02T10:00:05.000Z",
                "type": "response_item",
                "payload": {"type": "message", "role": "user",
                            "content": [{"type": "input_text",
                                         "text": f"hello from {session}"}]}}
        name = f"rollout-2026-01-02T10-00-00-{session}.jsonl"
        with open(os.path.join(self.codex, name), "w") as f:
            f.write(json.dumps(meta) + "\n" + json.dumps(item) + "\n")

    def raw(self, ns):
        return sorted(os.listdir(os.path.join(self.vault, ns, "raw", "sessions")))


GENERAL = """[project:general]
match_folders = ~, ~/Desktop
watermark = 2026-01-01
"""
DEMO = """[project:demo]
repo = /tmp/demo-app
match = demo-app
watermark = 2026-01-01
"""


def has(names, n):
    return any(sid(n) in f for f in names)


def in_scratch(body):
    root = tempfile.mkdtemp(prefix="a5n-folders-test-")
    try:
        body(root)
    finally:
        if os.environ.get("A5N_KEEP_TEST_DIR"):
            print(f"kept: {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)


def test_named_folders_and_projects_stay_apart(root):
    w = World(root)
    w.write_config(DEMO + GENERAL)
    w.claude_session(w.home, sid(1))
    w.claude_session(w.in_home("Desktop"), sid(2))
    w.claude_session(w.in_home("work", "demo-app"), sid(3))
    w.claude_session(w.in_home("notes"), sid(4))
    w.claude_session(w.in_home("Desktop", "taxes"), sid(5))
    w.codex_session(sid(6), w.home)
    w.codex_session(sid(7), w.in_home("Desktop"))
    w.codex_session(sid(8), w.in_home("notes"))
    r = w.capture()
    check(r.returncode == 0, f"capture runs: {r.stderr[:200]}")
    general, demo = w.raw("general"), w.raw("demo")
    check(has(general, 1), "home folder session goes to the named project")
    check(has(general, 2), "desktop session goes to the named project")
    check(has(demo, 3) and not has(general, 3),
          "a project under home still goes to its own project only")
    check(not has(general + demo, 4), "an unnamed folder under home stays out")
    check(not has(general + demo, 5), "a subfolder of a named folder stays out")
    check(has(general, 6) and has(general, 7),
          "Codex sessions are matched on the same folders")
    check(not has(general + demo, 8), "Codex session elsewhere stays out")


def test_same_line_for_another_user(root):
    """The same line on a machine with another user name, punctuation included,
    and only the folders of that machine."""
    w = World(root, user="bob.smith")
    w.write_config(GENERAL)
    w.claude_session(w.in_home("Desktop"), sid(1))
    w.claude_session(os.path.join(root, "users", "alice", "Desktop"), sid(2))
    r = w.capture()
    check(r.returncode == 0, f"capture runs: {r.stderr[:200]}")
    check(has(w.raw("general"), 1), "this machine's desktop is taken")
    check(not has(w.raw("general"), 2), "another user's desktop is not")


def test_folder_name_with_non_ascii_letters(root):
    w = World(root)
    w.write_config("""[project:general]
match_folders = ~/Masaüstü
watermark = 2026-01-01
""")
    w.claude_session(w.in_home("Masaüstü"), sid(1))
    r = w.capture()
    check(r.returncode == 0, f"capture runs: {r.stderr[:200]}")
    check(has(w.raw("general"), 1), "a localized desktop folder name works")


def test_user_name_contains_a_match(root):
    w = World(root, user="demo-app")
    w.write_config(DEMO + GENERAL)
    w.claude_session(w.home, sid(1))
    r = w.capture()
    check(r.returncode == 0, f"does not stop the run: {r.stderr[:200]}")
    check(has(w.raw("general"), 1) and w.raw("demo") == [],
          "a named folder wins over a substring in the user name")


def test_off_by_default(root):
    w = World(root)
    w.write_config(DEMO)
    w.claude_session(w.home, sid(1))
    r = w.capture()
    check(r.returncode == 0, f"capture runs: {r.stderr[:200]}")
    check(w.raw("demo") == [] and w.raw("general") == [],
          "without match_folders the home folder stays out of the vault")


def test_section_name_is_not_a_substring(root):
    """A section with no match falls back to its name. One with match_folders
    must not, or any folder containing "general" would be pulled in."""
    w = World(root)
    w.write_config(GENERAL)
    w.claude_session(w.in_home("general-ledger"), sid(1))
    r = w.capture()
    check(r.returncode == 0, f"capture runs: {r.stderr[:200]}")
    check(w.raw("general") == [], "the section name is not used as a match")


def test_bad_configs(root):
    w = World(root)
    for what, projects in (
        ("match and match_folders together", """[project:general]
match_folders = ~
match = demo-app
watermark = 2026-01-01
"""),
        ("one folder in two projects", GENERAL + """[project:other]
match_folders = ~/Desktop/
watermark = 2026-01-01
"""),
        ("a relative folder", """[project:general]
match_folders = Desktop
watermark = 2026-01-01
"""),
    ):
        w.write_config(projects)
        r = w.capture()
        check(r.returncode != 0 and "match_folders" in r.stdout + r.stderr,
              f"refused: {what}")


def test_project_list_keeps_its_columns(root):
    """setup.sh reads this with IFS=tab, and read collapses an empty field."""
    w = World(root)
    w.write_config(GENERAL)
    r = w.project_list()
    cols = r.stdout.rstrip("\n").split("\t")
    check(r.returncode == 0 and cols[0] == "general" and cols[1] != ""
          and cols[2] == "2026-01-01",
          f"--projects keeps the watermark in its column: {cols}")


def main():
    for t in (test_named_folders_and_projects_stay_apart,
              test_same_line_for_another_user,
              test_folder_name_with_non_ascii_letters,
              test_user_name_contains_a_match,
              test_off_by_default,
              test_section_name_is_not_a_substring,
              test_bad_configs,
              test_project_list_keeps_its_columns):
        print(f"--- {t.__name__}")
        in_scratch(t)
    if FAILS:
        print(f"\n{len(FAILS)} FAILED")
        return 1
    print("\nall passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
