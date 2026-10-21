#!/usr/bin/env python3
"""Tests for reading the whole vault through the MCP server: long pages in
parts, reading from the end, listing a folder.

What this guards: a page used to be cut at 100 KB with no way to read on,
and an append only log keeps its newest entries at the end, so the cut hid
exactly what a "what happened lately" question needs. An agent with a
shell then reads the file directly, around the server's filters. Every
line of every page must be reachable through vault_page, and every page
through vault_list, with a profile's hidden pages left out of both.

Everything happens in a temporary directory: a scratch config.ini (passed
through A5N_CONFIG) and a scratch vault. No real vault is touched, no model
runs. Runs on macOS and Linux, needs only python3.

Usage: python3 tests/mcp-read.py
       A5N_KEEP_TEST_DIR=1 python3 tests/mcp-read.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCP = os.path.join(REPO, "scripts", "a5n-mcp.py")
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)
        if detail:
            print("     " + detail[:600].replace("\n", "\n     "))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def page(title, tags, date, body):
    return (f"---\ntitle: {title}\ntags: [{', '.join(tags)}]\n"
            f"source: manual\ndate: {date}\nstatus: active\n---\n\n"
            f"# {title}\n\n{body}\n")


def mcp(env, args, calls):
    msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}]
    for i, (name, arguments) in enumerate(calls, 1):
        msgs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                     "params": {"name": name, "arguments": arguments}})
    proc = subprocess.run(
        [sys.executable, MCP, *args], env=env, capture_output=True, text=True,
        input="\n".join(json.dumps(m) for m in msgs) + "\n")
    out = [json.loads(line) for line in proc.stdout.splitlines() if line]
    return [r["result"]["content"][0]["text"] for r in out[1:]]


def main():
    tmp = tempfile.mkdtemp(prefix="a5n-mcp-read-")
    try:
        run(tmp)
    finally:
        if os.environ.get("A5N_KEEP_TEST_DIR"):
            print(f"kept {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    if FAILS:
        print(f"\n{len(FAILS)} failed")
        return 1
    print("\nall passed")
    return 0


def run(tmp):
    vault = os.path.join(tmp, "vault")
    cfg = os.path.join(tmp, "config.ini")
    write(cfg, f"""[vault]
path = {vault}

[mcp:assistant]
hide_tags = security

[project:shop]
match = shop
watermark = 2026-01-01
""")
    env = dict(os.environ, A5N_CONFIG=cfg)

    # a log of about 300 KB, numbered entries, newest at the end
    entries = [f"## [2026-09-{(i % 28) + 1:02d}] ingest | entry-{i:05d} "
               + "x" * 280 for i in range(1000)]
    write(os.path.join(vault, "shop", "log.md"),
          "# shop log\n\n" + "\n".join(entries) + "\n")
    write(os.path.join(vault, "shop", "index.md"), "# shop\n")
    write(os.path.join(vault, "shop", "sources", "sessions", ".gitkeep"), "")
    write(os.path.join(vault, "shop", "decisions", "old-choice.md"),
          page("Old choice", ["shop", "decision"], "2026-03-01", "Old."))
    write(os.path.join(vault, "shop", "decisions", "new-choice.md"),
          page("New choice", ["shop", "decision"], "2026-10-01", "New."))
    write(os.path.join(vault, "shop", "decisions", "csrf-fix-plan.md"),
          page("CSRF fix plan", ["shop", "decision", "security"],
               "2026-10-02", "How the hole is closed."))
    write(os.path.join(vault, "shop", "raw", "sessions", "x.md"), "raw")
    for i in range(7):
        write(os.path.join(vault, "patterns", f"lesson-{i}.md"),
              page(f"Lesson {i}", ["pattern"], f"2026-08-0{i + 1}", "L."))

    log = "shop/log.md"
    parts, start, guard = [], 1, 0
    while guard < 20:
        guard += 1
        text = mcp(env, [], [("vault_page", {"path": log, "start_line": start})])[0]
        parts.append(text)
        m = re.search(r"call vault_page with start_line=(\d+)", text)
        if not m:
            break
        start = int(m.group(1))
    body = "\n".join(re.sub(r"\n\n\[lines .*\]$", "", p) for p in parts)
    check("a long page comes in more than one part", len(parts) > 2,
          f"{len(parts)} parts")
    check("each part stays under the cap",
          all(len(p.encode()) < 100 * 1024 + 300 for p in parts))
    check("the parts together hold every entry, in order, once",
          re.findall(r"entry-(\d{5})", body)
          == [f"{i:05d}" for i in range(1000)])
    check("a part never cuts a line in half",
          all(len(m) == 280 for m in re.findall(r"x+", body)))

    tail = mcp(env, [], [("vault_page", {"path": log, "start_line": -3})])[0]
    check("a negative start_line reads the end",
          "entry-00999" in tail and "entry-00997" in tail
          and "entry-00996" not in tail and "goes on" not in tail, tail)
    past = mcp(env, [], [("vault_page", {"path": log, "start_line": 99999})])[0]
    check("start_line past the end says how long the page is",
          "past the end" in past, past)
    short = mcp(env, [], [("vault_page", {"path": "shop/index.md"})])[0]
    check("a short page comes whole, without a part note",
          short.strip() == "# shop", short)

    res = mcp(env, [], [
        ("vault_list", {"path": "shop/decisions"}),
        ("vault_list", {"path": "shop"}),
        ("vault_list", {"path": "patterns", "limit": 3}),
        ("vault_list", {"path": "patterns", "limit": 3, "offset": 6}),
        ("vault_list", {"path": "shop/raw"}),
        ("vault_list", {"path": "../"}),
        ("vault_list", {}),
    ])
    lines = [ln for ln in res[0].splitlines() if ln.startswith("- ")]
    check("a folder lists its pages newest first with title and date",
          lines and lines[0].startswith("- shop/decisions/csrf-fix-plan.md")
          and lines[-1].startswith("- shop/decisions/old-choice.md")
          and "New choice | 2026-10-01 | active" in res[0], res[0])
    check("a namespace lists its folders, raw/ left out",
          "shop/decisions" in res[1] and "raw" not in res[1], res[1])
    check("limit and offset page through a long folder",
          "showing 1-3" in res[2] and "4 more: call vault_list with offset=3" in res[2]
          and "showing 7-7" in res[3] and "lesson-0" in res[3], res[2] + res[3])
    check("raw/ and paths outside the vault are refused",
          "not a folder of pages" in res[4] and "without .. segments" in res[5],
          res[4] + res[5])
    check("the root lists namespaces and pattern folder",
          "shop" in res[6] and "patterns" in res[6], res[6])

    prof = mcp(env, ["--profile", "assistant"],
               [("vault_list", {"path": "shop/decisions"})])[0]
    check("a profile's hidden page is not listed",
          "csrf-fix-plan" not in prof and "new-choice" in prof
          and prof.startswith("shop/decisions: 2 pages"), prof)


if __name__ == "__main__":
    sys.exit(main())
