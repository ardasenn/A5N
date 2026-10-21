#!/usr/bin/env python3
"""Tests for the MCP server's write tools: a chess moves session and
GOALS.md, for a profile with allow_write.

What this guards: a client may write only the two pages the scheduled jobs
never touch, never past a running job (a unit's rollback would delete the
file), never over an older chess moves snapshot, and every write is masked,
committed alone and pushed. Without allow_write the tools do not exist.

Everything happens in a temporary directory: a scratch config.ini (passed
through A5N_CONFIG), a scratch vault that is its own git repository, and a
bare repository as its remote. No real vault is touched, no model runs.
Runs on macOS and Linux, needs only python3 and git.

Usage: python3 tests/mcp-write.py
       A5N_KEEP_TEST_DIR=1 python3 tests/mcp-write.py
"""
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCP = os.path.join(REPO, "scripts", "a5n-mcp.py")
DOT = "•"
TODAY = datetime.date.today().isoformat()
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)
        if detail:
            print("     " + str(detail)[:700].replace("\n", "\n     "))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True,
                          text=True).stdout


def mcp(env, args, calls, listing=False):
    msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}]
    if listing:
        msgs.append({"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                     "params": {}})
    for i, (name, arguments) in enumerate(calls, 2):
        msgs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                     "params": {"name": name, "arguments": arguments}})
    proc = subprocess.run(
        [sys.executable, MCP, *args], env=env, capture_output=True, text=True,
        input="\n".join(json.dumps(m) for m in msgs) + "\n")
    out = [json.loads(line) for line in proc.stdout.splitlines() if line]
    tools = []
    results = []
    for r in out[1:]:
        if "tools" in r.get("result", {}):
            tools = [t["name"] for t in r["result"]["tools"]]
        elif "result" in r:
            results.append((r["result"]["content"][0]["text"],
                            r["result"].get("isError", False)))
    return proc.returncode, tools, results, proc.stderr


def setup(tmp):
    vault = os.path.join(tmp, "vault")
    remote = os.path.join(tmp, "remote.git")
    cfg = os.path.join(tmp, "config.ini")
    write(cfg, f"""[vault]
path = {vault}

[privacy]
mask = yes

[sync]
enabled = yes
remote = origin
branch = main

[mcp:reader]
hide_tags = security

[mcp:assistant]
hide_tags = security
allow_write = chess-moves, goals

[mcp:notes-only]
allow_write = chess-moves

[project:shop]
match = shop
watermark = 2026-01-01
""")
    write(os.path.join(vault, ".gitignore"), ".a5n-logs/\n**/raw/\n")
    write(os.path.join(vault, "log.md"), "# log\n")
    write(os.path.join(vault, "GOALS.md"),
          "---\ntitle: GOALS\ntags: [goals]\ndate: 2026-01-01\nstatus: active\n"
          "---\n\n# Goals\n\n- Main goal: not stated yet\n")
    write(os.path.join(vault, "chess-moves", ".gitkeep"), "")
    write(os.path.join(vault, "shop", "index.md"), "# shop\n")
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", remote], check=True)
    git(vault, "init", "-q", "-b", "main")
    git(vault, "config", "user.email", "t@t.test")
    git(vault, "config", "user.name", "t")
    git(vault, "remote", "add", "origin", remote)
    git(vault, "add", "-A")
    git(vault, "commit", "-qm", "base")
    git(vault, "push", "-q", "origin", "main")
    return vault, remote, dict(os.environ, A5N_CONFIG=cfg)


def run(tmp):
    vault, remote, env = setup(tmp)

    _, plain, _, _ = mcp(env, [], [], listing=True)
    _, reader, _, _ = mcp(env, ["--profile", "reader"], [], listing=True)
    _, notes, _, _ = mcp(env, ["--profile", "notes-only"], [], listing=True)
    _, full, _, _ = mcp(env, ["--profile", "assistant"], [], listing=True)
    check("no profile and a read profile list no write tool",
          not any(t.startswith(("vault_save", "vault_update")) for t in plain + reader),
          plain + reader)
    check("allow_write lists exactly the tools it names",
          "vault_save_chess_move" in notes and "vault_update_goals" not in notes
          and {"vault_save_chess_move", "vault_update_goals"} <= set(full),
          notes + full)
    _, _, res, _ = mcp(env, ["--profile", "reader"], [
        ("vault_save_chess_move", {"title": "x", "body": "y"})])
    check("a write tool the profile lacks is an unknown tool",
          res[0][1] and res[0][0].startswith("unknown tool"), res)

    # an unrelated edit of the user's must stay out of the write's commit
    write(os.path.join(vault, "shop", "index.md"), "# shop\n\nedited by hand\n")

    body = ("We set the main goal.\n\nContact for the pilot: "
            "jane.roe@acme-corp.com, +905321234567.")
    rc, _, res, err = mcp(env, ["--profile", "assistant"], [
        ("vault_save_chess_move", {"title": "Hedef Görüşmesi", "body": body,
                                   "tags": ["Goals", "q4 plan"]})])
    rel = f"chess-moves/{TODAY}-hedef-gorusmesi.md"
    path = os.path.join(vault, rel)
    check("a chess move is saved under today's date and a folded slug",
          os.path.isfile(path) and not res[0][1], res or err)
    page = read(path) if os.path.isfile(path) else ""
    check("it gets the vault's frontmatter and page sections",
          page.startswith('---\ntitle: "Hedef Görüşmesi"\n'
                          "tags: [chess-moves, goals, q4-plan]\n"
                          f"source: manual\ndate: {TODAY}\nstatus: active\n---")
          and "# Hedef Görüşmesi" in page and "## Sources" in page
          and "[[GOALS]]" in page, page)
    check("personal data in it is masked",
          f"j{DOT*3}@acme-corp.com" in page and "jane.roe" not in page
          and f"+90{DOT*8}67" in page, page)
    check("the root log records it",
          f"## [{TODAY}] chess-moves | {TODAY}-hedef-gorusmesi (MCP profile assistant)"
          in read(os.path.join(vault, "log.md")))
    files = git(vault, "show", "--name-only", "--format=%s", "HEAD").split()
    check("one commit holds the page and the log line, nothing else",
          git(vault, "log", "-1", "--format=%s").strip()
          == f"chore: chess-moves {TODAY}-hedef-gorusmesi (mcp assistant)"
          and set(files) >= {rel, "log.md"} and "shop/index.md" not in files,
          files)
    check("the user's own edit stays uncommitted",
          "shop/index.md" in git(vault, "status", "--porcelain"))
    check("the commit is pushed",
          git(remote, "log", "-1", "--format=%s", "main").strip().startswith(
              "chore: chess-moves"), res)
    check("the lock is gone after the write",
          not os.path.exists(os.path.join(vault, ".a5n-logs", ".lock")))

    before = read(path)
    _, _, res, _ = mcp(env, ["--profile", "assistant"], [
        ("vault_save_chess_move", {"title": "Hedef Görüşmesi", "body": "other"})])
    check("an older snapshot is never overwritten",
          res[0][1] and "never edited" in res[0][0] and read(path) == before, res)

    os.makedirs(os.path.join(vault, ".a5n-logs"), exist_ok=True)
    write(os.path.join(vault, ".a5n-logs", ".lock"), "4242\n")
    head = git(vault, "rev-parse", "HEAD")
    _, _, res, _ = mcp(env, ["--profile", "assistant"], [
        ("vault_save_chess_move", {"title": "During a run", "body": "x"}),
        ("vault_update_goals", {"body": "# Goals\n\n- new", "summary": "s"})])
    check("while a job holds the lock nothing is written",
          all(r[1] and "A5N job is running" in r[0] for r in res)
          and not os.path.exists(os.path.join(vault, "chess-moves",
                                              f"{TODAY}-during-a-run.md"))
          and "Main goal: not stated yet" in read(os.path.join(vault, "GOALS.md"))
          and git(vault, "rev-parse", "HEAD") == head, res)
    check("a job's lock is left as it was",
          read(os.path.join(vault, ".a5n-logs", ".lock")) == "4242\n")
    os.remove(os.path.join(vault, ".a5n-logs", ".lock"))

    _, _, res, _ = mcp(env, ["--profile", "notes-only"], [
        ("vault_update_goals", {"body": "# Goals", "summary": "s"})])
    check("goals need their own allow_write", res[0][0].startswith("unknown tool"), res)

    _, _, res, _ = mcp(env, ["--profile", "assistant"], [
        ("vault_update_goals", {"body": "# Goals\n\n- Main goal: ship the app",
                                "summary": "main goal stated"})])
    goals = read(os.path.join(vault, "GOALS.md"))
    check("GOALS.md is replaced, its frontmatter kept with today's date",
          not res[0][1] and goals.startswith(
              f"---\ntitle: GOALS\ntags: [goals]\ndate: {TODAY}\nstatus: active\n---")
          and "ship the app" in goals and "not stated yet" not in goals,
          res[0][0] + "\n" + goals)
    check("the goals change is logged, committed alone and pushed",
          f"## [{TODAY}] goals | main goal stated (MCP profile assistant)"
          in read(os.path.join(vault, "log.md"))
          and git(remote, "log", "-1", "--format=%s", "main").strip()
          == "chore: goals updated (mcp assistant): main goal stated", res)
    _, _, res, _ = mcp(env, ["--profile", "assistant"], [
        ("vault_update_goals", {"body": "", "summary": "s"}),
        ("vault_save_chess_move", {"title": "!!!", "body": "x"})])
    check("an empty body or a slug with no letters is refused",
          all(r[1] for r in res), res)


def bad_profile(tmp):
    cfg = os.path.join(tmp, "bad.ini")
    write(cfg, f"""[vault]
path = {tmp}

[mcp:x]
allow_write = goal

[project:shop]
match = shop
""")
    rc, _, _, err = mcp(dict(os.environ, A5N_CONFIG=cfg), ["--profile", "x"], [])
    check("an unknown allow_write value stops the server",
          rc == 1 and "must be from: chess-moves, goals" in err, err)


def main():
    tmp = tempfile.mkdtemp(prefix="a5n-mcp-write-")
    try:
        run(tmp)
        bad_profile(tmp)
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


if __name__ == "__main__":
    sys.exit(main())
