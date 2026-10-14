#!/usr/bin/env python3
"""Tests for the capture of a session that was resumed after it was captured.

The bug this guards: ingest-discover.py capture called every candidate whose
raw already existed "present" and moved on, so when the user resumed
yesterday's session the continuation never reached the vault (18 sessions,
about 100 user messages on one machine, found 2026-10-06). Capture now
copies the part no earlier copy holds as <id>_cont<N>.jsonl.

Everything happens in a temporary directory: a scratch config.ini (passed
through A5N_CONFIG), a vault, a Claude projects folder and a Codex sessions
folder. No real vault or transcript is touched, no model runs. Runs on
macOS and Linux, needs only python3.

Usage: python3 tests/capture-continuation.py
       A5N_KEEP_TEST_DIR=1 python3 tests/capture-continuation.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISCOVER = os.path.join(REPO, "scripts", "ingest-discover.py")

FAILS = []


def check(cond, what):
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        FAILS.append(what)


class World:
    def __init__(self, root):
        self.root = root
        self.vault = os.path.join(root, "vault with space")
        self.claude = os.path.join(root, "claude", "projects")
        self.codex = os.path.join(root, "codex", "sessions")
        self.config = os.path.join(root, "config.ini")
        for d in (self.claude, self.codex,
                  os.path.join(self.vault, "demo", "raw", "sessions"),
                  os.path.join(self.vault, "demo", "sources", "sessions")):
            os.makedirs(d, exist_ok=True)
        with open(os.path.join(self.vault, "demo", "log.md"), "w") as f:
            f.write("# demo log\n")
        with open(self.config, "w") as f:
            f.write(f"""[vault]
path = {self.vault}
language = English
title = Test Vault
[agents]
claude_projects = {self.claude}
codex_sessions = {self.codex}
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
[project:demo]
repo = {root}/repo
match = demo-app
watermark = 2026-01-01
""")

    def run(self, *args):
        env = dict(os.environ, A5N_CONFIG=self.config)
        r = subprocess.run([sys.executable, DISCOVER, *args], env=env,
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout, r.stderr)
        return r

    def raw(self, name):
        return os.path.join(self.vault, "demo", "raw", "sessions", name)

    def raws(self):
        return sorted(os.listdir(os.path.join(self.vault, "demo", "raw",
                                              "sessions")))

    def log(self):
        with open(os.path.join(self.vault, "demo", "log.md")) as f:
            return f.read()

    def queue_ids(self):
        out = self.run("queue").stdout
        return [line.split("\t")[1] for line in out.splitlines() if line]

    def source_page(self, slug, raw_paths):
        body = "---\ntitle: t\ntags: [demo]\nsource: " + raw_paths[0] + \
            "\ndate: 2026-02-01\nstatus: active\n---\n# t\n## Sources\n" + \
            "".join(f"- {p}\n" for p in raw_paths)
        with open(os.path.join(self.vault, "demo", "sources", "sessions",
                               slug + ".md"), "w") as f:
            f.write(body)


def claude_rec(kind, uid, ts, text="x"):
    rec = {"type": kind, "uuid": uid, "timestamp": ts,
           "message": {"role": kind, "content": text}}
    return json.dumps(rec) + "\n"


def meta_rec(kind, value):
    # mode, custom-title and friends carry no uuid and no timestamp
    return json.dumps({"type": kind, "value": value}) + "\n"


def hook_rec(uid, ts):
    rec = {"type": "attachment", "uuid": uid, "timestamp": ts,
           "attachment": {"type": "hook_success", "stdout": "echo"}}
    return json.dumps(rec) + "\n"


def append(path, *lines):
    with open(path, "a") as f:
        f.writelines(lines)


def lines_of(path):
    with open(path) as f:
        return f.readlines()


def main():
    root = tempfile.mkdtemp(prefix="a5n capture ")
    try:
        w = World(root)
        sid = "11111111-aaaa-4bbb-8ccc-000000000001"
        folder = os.path.join(w.claude, "-home-u-work-demo-app")
        os.makedirs(folder)
        src = os.path.join(folder, sid + ".jsonl")
        append(src,
               claude_rec("user", "u1", "2026-02-01T10:00:00.000Z", "hello"),
               hook_rec("h1", "2026-02-01T10:00:01.000Z"),
               claude_rec("assistant", "a1", "2026-02-01T10:00:02.000Z"))

        # 1. a new session is captured as before, hook record filtered
        r = w.run("capture")
        check(w.raws() == [sid + ".jsonl"], "new session captured as <id>.jsonl")
        check(len(lines_of(w.raw(sid + ".jsonl"))) == 2,
              "base raw keeps 2 lines, hook record filtered")
        check("continued=0" in r.stdout, "summary reports continued=0")

        # 2. nothing changed: present, no part
        w.run("capture")
        check(w.raws() == [sid + ".jsonl"], "unchanged session stays present")

        # 3. resumed with model work: only the new part is copied
        append(src,
               claude_rec("user", "u2", "2026-02-02T09:00:00.000Z", "again"),
               hook_rec("h2", "2026-02-02T09:00:01.000Z"),
               claude_rec("assistant", "a2", "2026-02-02T09:00:02.000Z"))
        r = w.run("capture")
        part1 = sid + "_cont1.jsonl"
        check(w.raws() == [sid + ".jsonl", part1],
              "resumed session gets <id>_cont1.jsonl")
        check(lines_of(w.raw(sid + ".jsonl")) ==
              [claude_rec("user", "u1", "2026-02-01T10:00:00.000Z", "hello"),
               claude_rec("assistant", "a1", "2026-02-01T10:00:02.000Z")],
              "base raw left untouched")
        got = [json.loads(x)["uuid"] for x in lines_of(w.raw(part1))]
        check(got == ["u2", "a2"], "part 1 holds only the new records, filtered")
        check("copied=1" in r.stdout and "continued=1" in r.stdout,
              "summary counts the part as copied and continued")
        check(f"note | {sid[:8]}… grew after it was captured" in w.log(),
              "log gets a note for the part")
        check(sid not in w.log(), "the note carries no full id")

        # 4. queue: base first (older), then the part; traces stay apart
        check(w.queue_ids() == [sid, sid + "_cont1"],
              "queue lists base then part")
        w.source_page("2026-02-01-demo", [f"raw/sessions/{sid}.jsonl"])
        check(w.queue_ids() == [sid + "_cont1"],
              "a page with the base path dequeues only the base")
        with open(os.path.join(w.vault, "demo", "log.md"), "a") as f:
            f.write(f"\n## [2026-02-02] skip | {sid}_cont1 (test)\n")
        check(w.queue_ids() == [], "skip line of the part dequeues the part")
        os.remove(os.path.join(w.vault, "demo", "sources", "sessions",
                               "2026-02-01-demo.md"))
        check(w.queue_ids() == [sid],
              "skip line of the part does not dequeue the base")

        # 5. only metadata appended: no unit is worth it
        append(src, meta_rec("mode", "plan"), meta_rec("custom-title", "t"))
        w.run("capture")
        check(w.raws() == [sid + ".jsonl", part1],
              "metadata only tail is not copied")

        # 6. a later model reply becomes part 2, holding only what is new
        append(src, claude_rec("assistant", "a3", "2026-02-03T09:00:00.000Z"))
        w.run("capture")
        part2 = sid + "_cont2.jsonl"
        check(part2 in w.raws(), "next resume becomes _cont2")
        got = [json.loads(x).get("uuid") for x in lines_of(w.raw(part2))]
        check(got == [None, None, "a3"],
              "part 2 holds the tail since part 1 only")
        w.run("capture")
        check(len(w.raws()) == 3, "third run with no change adds nothing")

        # 7. a copy taken before the import filter existed (hook records
        # inside) must not make the whole session look new
        sid2 = "22222222-aaaa-4bbb-8ccc-000000000002"
        src2 = os.path.join(folder, sid2 + ".jsonl")
        old = [claude_rec("user", "v1", "2026-02-01T10:00:00.000Z"),
               hook_rec("k1", "2026-02-01T10:00:01.000Z"),
               claude_rec("assistant", "b1", "2026-02-01T10:00:02.000Z")]
        append(src2, *old)
        with open(w.raw(sid2 + ".jsonl"), "w") as f:
            f.writelines(old)  # unfiltered, as an early cp left it
        append(src2, claude_rec("assistant", "b2", "2026-02-04T10:00:00.000Z"))
        w.run("capture")
        got = [json.loads(x)["uuid"]
               for x in lines_of(w.raw(sid2 + "_cont1.jsonl"))]
        check(got == ["b2"], "unfiltered old copy: part holds only b2")

        # 8. the same id in a second folder (a worktree): one part only
        sid3 = "33333333-aaaa-4bbb-8ccc-000000000003"
        first = [claude_rec("user", "w1", "2026-02-01T10:00:00.000Z"),
                 claude_rec("assistant", "c1", "2026-02-01T10:00:02.000Z")]
        wt = os.path.join(w.claude, "-home-u-work-demo-app--worktrees-x")
        os.makedirs(wt)
        append(os.path.join(wt, sid3 + ".jsonl"), *first)
        w.run("capture")
        append(os.path.join(folder, sid3 + ".jsonl"), *first,
               claude_rec("assistant", "c2", "2026-02-05T10:00:00.000Z"))
        r = w.run("capture")
        parts3 = [n for n in w.raws() if n.startswith(sid3)]
        check(parts3 == [sid3 + ".jsonl", sid3 + "_cont1.jsonl"],
              "same id in two folders gives one part")
        w.run("capture")
        check(len([n for n in w.raws() if n.startswith(sid3)]) == 2,
              "and stays at one part on the next run")

        # 8b. first seen in two folders in the same run, the second one
        # longer: base from one, a part from the other, nothing lost
        sid5 = "55555555-aaaa-4bbb-8ccc-000000000005"
        short = [claude_rec("user", "z1", "2026-02-01T10:00:00.000Z"),
                 claude_rec("assistant", "d1", "2026-02-01T10:00:02.000Z")]
        append(os.path.join(wt, sid5 + ".jsonl"), *short)
        append(os.path.join(folder, sid5 + ".jsonl"), *short,
               claude_rec("assistant", "d2", "2026-02-05T11:00:00.000Z"))
        w.run("capture")
        names5 = [n for n in w.raws() if n.startswith(sid5)]
        held = []
        for n in names5:
            held += [json.loads(x)["uuid"] for x in lines_of(w.raw(n))]
        check(sorted(held) == ["d1", "d2", "z1"],
              "two folders in one run: every record lands exactly once")
        check(f"{sid5[:8]}… is a LARGER copy" not in w.log(),
              "two folders in one run: no false larger copy note")
        check(f"skip | {sid5}" not in w.log() and sid5 in w.queue_ids(),
              "two folders in one run: the base stays queued")

        # 9. Codex: a resumed rollout gets a part too
        day = os.path.join(w.codex, "2026", "02", "01")
        os.makedirs(day)
        cid = "44444444-aaaa-4bbb-8ccc-000000000004"
        rollout = os.path.join(day, f"rollout-2026-02-01T10-00-00-{cid}.jsonl")

        def cx(t, payload, ts):
            return json.dumps({"timestamp": ts, "type": t,
                               "payload": payload}) + "\n"
        append(rollout,
               cx("session_meta", {"id": cid, "cwd": "/home/u/work/demo-app"},
                  "2026-02-01T10:00:00.000Z"),
               cx("response_item", {"type": "message", "role": "user",
                                    "content": "hi"}, "2026-02-01T10:00:01.000Z"),
               cx("response_item", {"type": "message", "role": "assistant",
                                    "content": "yo"}, "2026-02-01T10:00:02.000Z"))
        w.run("capture")
        base = f"codex-{cid}"
        check(base + ".jsonl" in w.raws(), "Codex rollout captured")
        append(rollout,
               cx("event_msg", {"type": "token_count"}, "2026-02-06T10:00:00.000Z"),
               cx("response_item", {"type": "message", "role": "user",
                                    "content": "more"}, "2026-02-06T10:00:01.000Z"))
        w.run("capture")
        check(base + "_cont1.jsonl" not in w.raws(),
              "Codex tail with only a user message is not copied")
        append(rollout,
               cx("response_item", {"type": "function_call", "name": "sh"},
                  "2026-02-06T10:00:02.000Z"))
        w.run("capture")
        got = [json.loads(x)["payload"].get("role") or
               json.loads(x)["payload"]["type"]
               for x in lines_of(w.raw(base + "_cont1.jsonl"))]
        check(got == ["user", "function_call"],
              "Codex part holds the new items, telemetry filtered")

        # 10. dry run: counted, nothing written
        append(src, claude_rec("assistant", "a4", "2026-02-07T09:00:00.000Z"))
        before = w.raws()
        r = w.run("capture", "--dry-run")
        check(w.raws() == before, "dry run writes no file")
        check("would copy continuation: demo/" + sid + "_cont3" in r.stdout
              and "copied=1" in r.stdout,
              "dry run announces the part and counts it as copied")
    finally:
        if os.environ.get("A5N_KEEP_TEST_DIR"):
            print(f"kept: {root}")
        else:
            shutil.rmtree(root)

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED")
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
