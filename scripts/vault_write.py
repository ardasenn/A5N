"""The MCP server's only write path: a chess moves session and GOALS.md.

Why these two and nothing else: they are the vault's forward looking pages,
written only with the user and on request, and they are the only pages the
scheduled jobs never touch. A client writing there can never write the same
file as the ingest, so the vault keeps a single writer per file. A profile
opts in with allow_write; without it the server stays read only.

Why the server does the writing and not the client's own file tools: the
rules that keep the vault sound live here, on the machine, instead of in a
prompt the client may forget.
- A job running on this machine is never written past. A unit the ingest
  rolls back runs git reset --hard and git clean -fd, which would take a
  file written meanwhile with it. The write takes the jobs' own local lock
  (.a5n-logs/.lock), so it refuses while a job runs and a job that starts
  meanwhile waits the second it takes.
- An old chess moves file is never edited: each session is a new, dated
  snapshot, so the evolution of the user's thinking stays visible.
- Frontmatter, the page format and personal data masking are applied here.
- Each write is its own commit, so a bad GOALS.md rewrite is one revert
  away, and with [sync] on it is pushed at once. A push that cannot fast
  forward is left to the next job, which rebases and pushes local commits.
"""
import datetime
import json
import os
import re
import subprocess

import privacy

LOCK_NAME = os.path.join(".a5n-logs", ".lock")
CHESS_DIR = "chess-moves"
GOALS_FILE = "GOALS.md"
SLUG_MAX = 60
FOLD = str.maketrans("çğıöşüâîûÇĞİÖŞÜÂÎÛ", "cgiosuaiuCGIOSUAIU")


class WriteError(Exception):
    pass


def slugify(text):
    s = (text or "").translate(FOLD).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:SLUG_MAX].rstrip("-")


def _one_line(text, cap=120):
    return re.sub(r"\s+", " ", text or "").strip()[:cap]


class _Lock:
    """The jobs' local lock, taken without waiting: O_EXCL like the
    drivers' noclobber, so of a job and a write that start together exactly
    one gets it. A held lock is a refusal, even a stale looking one: the
    next job clears a stale lock, and a client guessing wrong about it
    would write next to a running unit."""

    def __init__(self, vault):
        self.path = os.path.join(vault, LOCK_NAME)

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            try:
                with open(self.path, encoding="utf-8") as f:
                    owner = f.read().strip() or "?"
            except OSError:
                owner = "?"
            raise WriteError(
                f"an A5N job is running on this machine (pid {owner}); the "
                f"vault takes no other writes meanwhile. Try again in a few "
                f"minutes, nothing was written.")
        with os.fdopen(fd, "w") as f:
            f.write(f"{os.getpid()}\n")
        return self

    def __exit__(self, *exc):
        try:
            os.remove(self.path)
        except FileNotFoundError:
            pass
        return False


def _git(vault, *args, timeout=60):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    return subprocess.run(["git", "-C", vault, *args], capture_output=True,
                          text=True, timeout=timeout, env=env)


def _commit(vault, paths, message):
    """Only these paths: an edit the user has open elsewhere in the vault
    stays theirs, uncommitted."""
    add = _git(vault, "add", "--", *paths)
    commit = _git(vault, "commit", "-q", "-m", message, "--", *paths)
    if add.returncode or commit.returncode:
        raise WriteError("the page is written but git commit failed: "
                         + _one_line(add.stderr + commit.stderr, 300))


def _push(vault, cfg):
    """Outside the lock: a push leaves the working tree alone, and a slow
    network must not hold back a job that is waiting for the lock."""
    sync = cfg["sync"]
    if sync["enabled"] != "yes":
        return "committed"
    branch = _git(vault, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if branch != sync["branch"]:
        return (f"committed on branch {branch}, not pushed (sync pushes "
                f"{sync['branch']})")
    try:
        push = _git(vault, "push", "-q", sync["remote"],
                    f"HEAD:{sync['branch']}", timeout=45)
    except subprocess.TimeoutExpired:
        push = None
    if push is not None and push.returncode == 0:
        return "committed and pushed"
    return "committed; the push did not go through, the next A5N run pushes it"


def _log_line(vault, line):
    path = os.path.join(vault, "log.md")
    text = ""
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
    if text and not text.endswith("\n"):
        text += "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + ("\n" if text else "") + line + "\n")
    return "log.md"


def _today():
    return datetime.date.today().isoformat()


def save_chess_move(vault, cfg, pol, profile, title, slug, body, tags=None):
    title = _one_line(title, 200)
    if not title:
        raise WriteError("title is empty")
    slug = slugify(slug or title)
    if not slug:
        raise WriteError("slug has no letters or digits")
    body = (body or "").strip()
    if not body:
        raise WriteError("body is empty")
    today = _today()
    rel = f"{CHESS_DIR}/{today}-{slug}.md"
    path = os.path.join(vault, rel)

    extra = [slugify(t) for t in (tags or []) if slugify(t)]
    all_tags = ["chess-moves"] + [t for t in extra if t != "chess-moves"]
    if not body.startswith("# "):
        body = f"# {title}\n\n{body}"
    if "\n## Sources" not in body:
        body += (f"\n\n## Sources\n\n- manual: a conversation through the "
                 f"MCP client '{profile}', {today}")
    if "\n## Related" not in body and os.path.isfile(
            os.path.join(vault, GOALS_FILE)):
        body += "\n\n## Related\n\n- [[GOALS]]"
    page = (f"---\ntitle: {json.dumps(title, ensure_ascii=False)}\n"
            f"tags: [{', '.join(all_tags)}]\nsource: manual\n"
            f"date: {today}\nstatus: active\n---\n\n{body}\n")
    if pol["enabled"]:
        page = privacy.mask(page, pol)[0]

    with _Lock(vault):
        if os.path.exists(path):
            raise WriteError(
                f"{rel} exists. A chess moves session is a dated snapshot "
                f"and is never edited; save this one under another slug.")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(page)
        log = _log_line(vault, f"## [{today}] chess-moves | {today}-{slug} "
                               f"(MCP profile {profile})")
        _commit(vault, [rel, log],
                f"chore: chess-moves {today}-{slug} (mcp {profile})")
    return f"saved {rel}: {_push(vault, cfg)}"


def update_goals(vault, cfg, pol, profile, body, summary):
    body = (body or "").strip()
    summary = _one_line(summary)
    if not body:
        raise WriteError("body is empty")
    if not summary:
        raise WriteError("summary is empty: say in one line what changed")
    if pol["enabled"]:
        body = privacy.mask(body, pol)[0]
        summary = privacy.mask(summary, pol)[0]
    today = _today()
    path = os.path.join(vault, GOALS_FILE)

    with _Lock(vault):
        old = ""
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                old = f.read()
        m = re.match(r"^---\n(.*?)\n---\n", old, re.S)
        if m:
            fm = m.group(1)
            fm = (re.sub(r"^date:.*$", f"date: {today}", fm, flags=re.M)
                  if re.search(r"^date:", fm, re.M) else fm + f"\ndate: {today}")
        else:
            fm = (f"title: GOALS\ntags: [goals]\nsource: manual\n"
                  f"date: {today}\nstatus: active")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"---\n{fm}\n---\n\n{body}\n")
        log = _log_line(vault, f"## [{today}] goals | {summary} "
                               f"(MCP profile {profile})")
        _commit(vault, [GOALS_FILE, log],
                f"chore: goals updated (mcp {profile}): {summary}")
    state = _push(vault, cfg)
    before = len(old.splitlines())
    after = len(body.splitlines()) + len(fm.splitlines()) + 3
    return (f"GOALS.md replaced, {before} lines before, {after} now: {state}. "
            f"The previous version is in git history.")
