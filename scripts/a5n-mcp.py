#!/usr/bin/env python3
"""A5N MCP server: gives any MCP capable agent read access to the vault.

This is the read path. The ingest writes the vault; this server is how a
coding agent working in some project actually consults it, so the loop
"the agent proposes the approach you already rejected" gets closed. The
calling agent does the synthesis with its own model, this server only
returns data, so a query costs nothing beyond what the agent was already
spending.

Register once, then every session of that agent can search the vault:

    claude mcp add --scope user a5n -- python3 <repo>/scripts/a5n-mcp.py

    # Codex, in ~/.codex/config.toml:
    [mcp_servers.a5n]
    command = "python3"
    args = ["<repo>/scripts/a5n-mcp.py"]

    # a client that should see less, with an [mcp:<name>] section:
    python3 <repo>/scripts/a5n-mcp.py --profile <name>

Personal data is masked on the way out when [privacy] mask = yes, with the
same rules the ingest applies to its pages (scripts/privacy.py). The
ingest already wrote its pages masked; this also covers pages written by
hand or in an interactive session.

A profile hides pages from one client: every page whose frontmatter tags
meet hide_tags, every page of a hide_projects namespace, and every line of
the remaining pages that names a hidden page (an index entry, a wikilink,
a log line). Without that last step an index line would hand out the very
summary the page was hidden for. The filtering happens here, on the
machine, because asking the client's model to skip pages it can read is no
separation at all. It separates only what goes through this server: a
client that can also read the vault's files directly (a shell, a file
tool) needs that access taken away on its own side.

Implementation notes. Standard library only, like the rest of A5N: the MCP
stdio transport is newline delimited JSON-RPC 2.0, which needs no SDK.
stdout carries protocol messages and nothing else; diagnostics go to
stderr. The server is read only and never opens anything under raw/:
transcripts are data for the ingest, not for queries, and they are large
enough to flood an agent's context. The one exception to read only is
opt in per profile (allow_write): saving a chess moves session and
replacing GOALS.md, the two pages no scheduled job writes. scripts/
vault_write.py says why exactly those and how a write stays out of a
running job's way.

Tools:
    vault_overview()                 orientation: namespaces, counts, patterns
    vault_search(query, project?, limit?)   ranked term search over pages
    vault_list(path?, limit?, offset?)      the pages of one folder, newest first
    vault_page(path, start_line?)    one page; a long one comes in parts
    vault_save_chess_move(title, body, slug?, tags?)  allow_write chess-moves
    vault_update_goals(body, summary)                 allow_write goals

Why paging and listing exist: a page used to be cut at PAGE_CAP with no way
to read on, and an append only log keeps its newest entries at the end, so
the cut removed exactly the part a "what happened lately" question needs.
An agent that also has a shell then reads the file directly, around every
filter this server applies. Everything the vault holds as pages has to be
reachable through the server, or the server is not the read path.
"""
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load, mcp_profile, ConfigError  # noqa: E402
import privacy  # noqa: E402
import vault_write  # noqa: E402

PROTOCOL_VERSION = "2025-06-18"
SKIP_DIRS = {".git", ".obsidian", ".a5n-logs", "raw", ".claude", "node_modules"}
EXCERPT_CHARS = 160
PAGE_CAP = 100 * 1024
LIST_DEFAULT = 200
LIST_CAP = 1000

TOOLS = [
    {
        "name": "vault_overview",
        "description": (
            "Orientation for the knowledge vault: the project namespaces with "
            "their page counts, the cross project pattern pages, and the root "
            "index. Call this first to learn what the vault knows about, "
            "then vault_list to browse a folder."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "vault_search",
        "description": (
            "Search the vault pages (session summaries, decisions, bugs, "
            "entities, concepts, patterns) for the given terms. Returns "
            "ranked pages with matching line excerpts. Use vault_page to "
            "read a full page from the results."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search terms, matched case insensitively.",
                },
                "project": {
                    "type": "string",
                    "description": "Optional namespace to search in. Empty searches everything.",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum pages to return, default 10, cap 25.",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "vault_list",
        "description": (
            "List the pages of one vault folder, newest first, with title, "
            "date and status, plus its subfolders. Use it to browse: all "
            "decisions or bugs of a project, the pattern pages, the "
            "strategy notes. Empty path lists the vault root."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": (
                        "Vault relative folder, for example "
                        "'<project>/decisions' or 'patterns'. Empty for "
                        "the root."),
                },
                "limit": {
                    "type": "integer",
                    "description": f"Pages to return, default {LIST_DEFAULT}, cap {LIST_CAP}.",
                },
                "offset": {
                    "type": "integer",
                    "description": "Pages to skip, for the next part of a long folder.",
                },
            },
        },
    },
    {
        "name": "vault_page",
        "description": (
            "Read one vault page. The path is vault relative, as returned by "
            "vault_search, vault_list or vault_overview. A page longer than "
            f"{PAGE_CAP // 1024} KB comes in parts; each part ends with the "
            "start_line of the next one. Logs keep their newest entries at "
            "the end: a negative start_line reads from there."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Vault relative path of a .md page.",
                },
                "start_line": {
                    "type": "integer",
                    "description": (
                        "First line to return, 1 based, default 1. A "
                        "negative number counts from the end: -200 starts "
                        "at the 200th line from the end."),
                },
            },
            "required": ["path"],
        },
    },
]

# Listed only to a profile whose allow_write names them; to everyone else
# they do not exist, and a call is refused as an unknown tool.
WRITE_TOOLS = {
    "chess-moves": {
        "name": "vault_save_chess_move",
        "description": (
            "Save a strategy conversation with the user as a new chess moves "
            "session: their goals, the moves planned, the priorities argued. "
            "Call it only when the user asks for the conversation to be "
            "saved. It becomes chess-moves/<today>-<slug>.md; an older "
            "session is never edited, each save is a new dated snapshot. "
            "Write the body in the vault's language as a readable summary "
            "of what was decided and why, not a transcript. Frontmatter, "
            "masking of personal data and the commit are done for you."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string",
                          "description": "Short title of the session."},
                "body": {"type": "string",
                         "description": "Markdown page body, without frontmatter."},
                "slug": {"type": "string",
                         "description": "Optional kebab case name; made from the title when left out."},
                "tags": {"type": "array", "items": {"type": "string"},
                         "description": "Optional extra tags; chess-moves is always added."},
            },
            "required": ["title", "body"],
        },
    },
    "goals": {
        "name": "vault_update_goals",
        "description": (
            "Replace GOALS.md, the always current summary of the user's "
            "goals, with new content. Only from what the user states, and "
            "only after they approved the new text. Read the current "
            "GOALS.md with vault_page first and send the COMPLETE new body: "
            "whatever the body leaves out is gone from the file (the old "
            "version stays in git history). Usually called at the end of "
            "a chess moves session, after vault_save_chess_move."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "body": {"type": "string",
                         "description": "The whole new page body, without frontmatter."},
                "summary": {"type": "string",
                            "description": "One line: what changed and why."},
            },
            "required": ["body", "summary"],
        },
    },
}
WRITE_TOOL_TARGET = {t["name"]: target for target, t in WRITE_TOOLS.items()}


def log(msg):
    sys.stderr.write(f"a5n-mcp: {msg}\n")
    sys.stderr.flush()


def iter_pages(vault, project=""):
    """Yield (relpath, abspath) for every searchable .md page."""
    root = os.path.join(vault, project) if project else vault
    if not os.path.isdir(root):
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if fn.endswith(".md"):
                ap = os.path.join(dirpath, fn)
                yield os.path.relpath(ap, vault), ap


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


class View:
    """What this client may see: the privacy policy plus the profile's
    hidden pages. Rebuilt per tool call, because the ingest adds pages
    while a long agent session keeps the server running."""

    def __init__(self, vault, pol, prof):
        self.pol = pol
        self.hidden = set()
        self.hidden_ns = set(prof["hide_projects"]) if prof else set()
        tokens = set()
        if prof and (prof["hide_tags"] or prof["hide_projects"]):
            for rel, ap in iter_pages(vault):
                ns = rel.split("/", 1)[0] if "/" in rel else ""
                if ns in self.hidden_ns or (
                        prof["hide_tags"]
                        and page_tags(read_head(ap)) & prof["hide_tags"]):
                    self.hidden.add(rel)
                    base = os.path.basename(rel)[:-3]
                    tokens.add(base)
                    # log lines name a source page by its slug, without
                    # the date prefix its file name carries
                    m = SOURCE_NAME_RX.match(base)
                    if m and len(m.group(1)) >= 12:
                        tokens.add(m.group(1))
        self.tokens = tokens

    def visible(self, rel):
        return rel not in self.hidden

    def render(self, text):
        """Page text as this client receives it."""
        if self.tokens:
            kept = []
            for line in text.split("\n"):
                if self.tokens.isdisjoint(WORD_RX.findall(line)):
                    kept.append(line)
            text = "\n".join(kept)
        if self.pol["enabled"]:
            text = privacy.mask(text, self.pol)[0]
        return text


FM_RX = re.compile(r"^---\n(.*?)\n---", re.S)
TAGS_INLINE_RX = re.compile(r"^tags:\s*\[(.*?)\]", re.M)
TAGS_BLOCK_RX = re.compile(r"^tags:\s*\n((?:[ \t]*-[^\n]*\n?)+)", re.M)
SOURCE_NAME_RX = re.compile(r"^\d{4}-\d{2}-\d{2}-(.+)$")
# a page name as it shows up in a line: kebab case, any letters
WORD_RX = re.compile(r"[\w][\w\-]*[\w]")
DATE_RX = re.compile(r"^date:\s*(\d{4}-\d{2}-\d{2})", re.M)
TITLE_RX = re.compile(r"^title:\s*(.+)$", re.M)
STATUS_RX = re.compile(r"^status:\s*(\S+)", re.M)


def page_meta(text):
    """(title, status, date) from frontmatter, best effort."""
    m = FM_RX.match(text)
    fm = m.group(1) if m else ""
    title = TITLE_RX.search(fm)
    status = STATUS_RX.search(fm)
    date = DATE_RX.search(fm)
    return (
        title.group(1).strip() if title else "",
        status.group(1) if status else "",
        date.group(1) if date else "",
    )


def read_head(path, size=4096):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read(size)


def page_tags(text):
    """Lower cased frontmatter tags, inline [a, b] or a block list."""
    m = FM_RX.match(text)
    if not m:
        return set()
    fm = m.group(1) + "\n"
    found = TAGS_INLINE_RX.search(fm)
    if found:
        items = found.group(1).split(",")
    else:
        block = TAGS_BLOCK_RX.search(fm)
        items = [ln.strip()[1:] for ln in block.group(1).splitlines()
                 if ln.strip().startswith("-")] if block else []
    return {i.strip().strip("'\"").lower() for i in items if i.strip()}


def recency_bonus(date_str, today):
    """0..3, newer pages score a little higher on equal term hits."""
    try:
        age = (today - datetime.date.fromisoformat(date_str)).days
    except ValueError:
        return 0
    if age <= 14:
        return 3
    if age <= 60:
        return 2
    if age <= 180:
        return 1
    return 0


def do_search(vault, view, query, project, limit):
    # project is an MCP argument, which makes it attacker adjacent: a
    # prompt injected caller chooses it freely, and os.path.join with an
    # absolute or ../ value would walk right out of the vault. Only a bare
    # name naming an existing vault directory is accepted.
    if project:
        if project != os.path.basename(project) or project.startswith("."):
            return f"project must be a bare namespace name, got: {project}"
        if (not os.path.isdir(os.path.join(vault, project))
                or project in view.hidden_ns):
            return f"no such namespace in the vault: {project}"
    terms = [t for t in re.split(r"\W+", query.lower()) if len(t) >= 2]
    if not terms:
        return "query has no searchable terms"
    limit = max(1, min(int(limit or 10), 25))
    today = datetime.date.today()
    scored = []
    for rel, ap in iter_pages(vault, project):
        if not view.visible(rel):
            continue
        text = view.render(read_text(ap))
        low = text.lower()
        counts = [low.count(t) for t in terms]
        if not any(counts):
            continue
        # every term capped so one spammy page cannot drown the ranking
        score = sum(min(c, 8) for c in counts)
        score += 4 * sum(1 for c in counts if c)  # breadth over repetition
        title, status, date = page_meta(text)
        head = (title + " " + rel).lower()
        score += 5 * sum(1 for t in terms if t in head)
        score += recency_bonus(date, today)
        excerpts = []
        for line in text.splitlines():
            ll = line.lower()
            if any(t in ll for t in terms) and line.strip():
                excerpts.append(line.strip()[:EXCERPT_CHARS])
                if len(excerpts) == 3:
                    break
        scored.append((score, rel, title, status, date, excerpts))
    if not scored:
        where = f" in {project}" if project else ""
        return f"no pages{where} match: {query}"
    scored.sort(key=lambda s: (-s[0], s[1]))
    out = [f"{len(scored)} pages match, top {min(limit, len(scored))}:"]
    for score, rel, title, status, date, excerpts in scored[:limit]:
        head = f"\n## {rel}"
        meta = ", ".join(x for x in (title, status, date) if x)
        if meta:
            head += f"\n{meta}"
        out.append(head)
        out.extend(f"> {e}" for e in excerpts)
    return "\n".join(out)


def do_page(vault, view, path, start_line=1):
    if not path or path.startswith(("/", "~")) or ".." in path.split("/"):
        return None, "path must be vault relative, without .. segments"
    if not path.endswith(".md"):
        return None, "only .md pages can be read"
    if "raw/" in path or path.startswith("raw"):
        return None, ("raw/ holds transcripts, not pages; they are ingest "
                      "input and too large for a query context")
    ap = os.path.realpath(os.path.join(vault, path))
    if not ap.startswith(os.path.realpath(vault) + os.sep):
        return None, "path resolves outside the vault"
    if not os.path.isfile(ap):
        return None, f"no such page: {path}"
    rel = os.path.relpath(ap, os.path.realpath(vault))
    if not view.visible(rel):
        return None, f"not available to this client: {path}"
    try:
        start = int(start_line or 1)
    except (TypeError, ValueError):
        return None, f"start_line must be a whole number, got: {start_line}"
    # Lines of the page as this client sees it: hidden lines are already
    # gone, so the numbers stay consistent from one part to the next.
    lines = view.render(read_text(ap)).split("\n")
    if len(lines) > 1 and lines[-1] == "":
        lines.pop()  # the file's final newline ends a line, it is not one
    total = len(lines)
    if start < 0:
        start = max(1, total + start + 1)
    start = max(start, 1)
    if start > total:
        return None, f"start_line {start} is past the end, the page has {total} lines"
    out, size, end = [], 0, start - 1
    while end < total:
        need = len(lines[end].encode("utf-8")) + 1
        if out and size + need > PAGE_CAP:
            break
        out.append(lines[end])
        size += need
        end += 1
    text = "\n".join(out)
    if start > 1 or end < total:
        note = f"[lines {start}-{end} of {total}"
        if end < total:
            note += f"; the page goes on, call vault_page with start_line={end + 1}"
        text += "\n\n" + note + "]"
    return text, None


def do_list(vault, view, path, limit, offset):
    path = (path or "").strip().strip("/")
    parts = path.split("/") if path else []
    if path.startswith("~") or os.path.isabs(path) or ".." in parts:
        return "path must be vault relative, without .. segments"
    if any(p in SKIP_DIRS or p.startswith(".") for p in parts):
        return f"not a folder of pages: {path}"
    root = os.path.realpath(vault)
    ap = os.path.realpath(os.path.join(vault, path))
    if ap != root and not ap.startswith(root + os.sep):
        return "path resolves outside the vault"
    if not os.path.isdir(ap) or (parts and parts[0] in view.hidden_ns):
        return f"no such folder in the vault: {path}"
    try:
        limit = max(1, min(int(limit or LIST_DEFAULT), LIST_CAP))
        offset = max(0, int(offset or 0))
    except (TypeError, ValueError):
        return "limit and offset must be whole numbers"

    folders, pages = [], []
    for entry in sorted(os.listdir(ap)):
        full = os.path.join(ap, entry)
        if os.path.isdir(full):
            if (entry not in SKIP_DIRS and not entry.startswith(".")
                    and not (not parts and entry in view.hidden_ns)):
                folders.append(entry)
        elif entry.endswith(".md"):
            rel = f"{path}/{entry}" if path else entry
            if view.visible(rel):
                title, status, date = page_meta(read_head(full))
                pages.append((date, rel, title, status))
    # newest first; undated pages (indexes, schema) after the dated ones
    pages.sort(key=lambda p: (p[0] or "0000", p[1]), reverse=True)

    where = path or "vault root"
    shown = pages[offset:offset + limit]
    out = [f"{where}: {len(pages)} pages, newest first"
           + (f", showing {offset + 1}-{offset + len(shown)}" if shown else "")]
    if folders:
        out.append("Folders: " + ", ".join(f"{path}/{f}" if path else f
                                           for f in folders))
    for date, rel, title, status in shown:
        meta = " | ".join(x for x in (title, date, status) if x)
        out.append(f"- {rel}" + (f" | {meta}" if meta else ""))
    if offset + len(shown) < len(pages):
        out.append(f"[{len(pages) - offset - len(shown)} more: call vault_list "
                   f"with offset={offset + len(shown)}]")
    # titles go through the same filter as page text: masked, and a line
    # that names a hidden page is dropped
    return view.render("\n".join(out))


def do_overview(vault, view):
    out = []
    namespaces = []
    for entry in sorted(os.listdir(vault)):
        base = os.path.join(vault, entry)
        if (os.path.isdir(base) and os.path.isdir(os.path.join(base, "sources"))
                and entry not in view.hidden_ns):
            namespaces.append(entry)
    out.append(f"Namespaces ({len(namespaces)}):")
    for ns in namespaces:
        counts = []
        for cat in ("sources/sessions", "entities", "concepts", "decisions",
                    "bugs", "syntheses"):
            d = os.path.join(vault, ns, cat)
            if os.path.isdir(d):
                n = sum(1 for f in os.listdir(d) if f.endswith(".md")
                        and view.visible(f"{ns}/{cat}/{f}"))
                if n:
                    counts.append(f"{cat.split('/')[-1]} {n}")
        out.append(f"- {ns}: " + (", ".join(counts) if counts else "empty"))

    pat_dir = os.path.join(vault, "patterns")
    pats = sorted(f for f in os.listdir(pat_dir) if f.endswith(".md")
                  and view.visible(f"patterns/{f}")) \
        if os.path.isdir(pat_dir) else []
    out.append(f"\nCross project patterns ({len(pats)}):")
    out.extend(f"- patterns/{p}" for p in pats) if pats else out.append("(none yet)")

    idx = os.path.join(vault, "index.md")
    if os.path.isfile(idx):
        out.append("\nRoot index.md:\n" + view.render(read_text(idx))[:4000])
    return "\n".join(out)


def tool_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def handle(cfg, pol, prof, method, params):
    vault = cfg["vault"]["path"]
    writes = prof["allow_write"] if prof else set()
    if method == "initialize":
        return {
            "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "a5n", "version": "1.0.0"},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS + [WRITE_TOOLS[t] for t in sorted(writes)]}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        view = View(vault, pol, prof)
        if name == "vault_overview":
            return tool_result(do_overview(vault, view))
        if name == "vault_search":
            return tool_result(do_search(
                vault, view, args.get("query", ""), args.get("project", ""),
                args.get("limit", 10)))
        if name == "vault_list":
            return tool_result(do_list(
                vault, view, args.get("path", ""), args.get("limit"),
                args.get("offset")))
        if name == "vault_page":
            text, err = do_page(vault, view, args.get("path", ""),
                                args.get("start_line", 1))
            return tool_result(err, True) if err else tool_result(text)
        target = WRITE_TOOL_TARGET.get(name)
        if target in writes:
            try:
                if target == "chess-moves":
                    return tool_result(vault_write.save_chess_move(
                        vault, cfg, pol, prof["name"], args.get("title", ""),
                        args.get("slug", ""), args.get("body", ""),
                        args.get("tags") or []))
                return tool_result(vault_write.update_goals(
                    vault, cfg, pol, prof["name"], args.get("body", ""),
                    args.get("summary", "")))
            except vault_write.WriteError as exc:
                return tool_result(str(exc), True)
        return tool_result(f"unknown tool: {name}", True)
    return None  # unknown method


def main(argv):
    prof = None
    try:
        cfg = load()
        vault = cfg["vault"]["path"]
        pol = privacy.policy(cfg)
        if argv[1:2] == ["--profile"]:
            if len(argv) < 3:
                raise ConfigError("--profile needs a name")
            prof = mcp_profile(cfg, argv[2])
        elif argv[1:]:
            raise ConfigError(f"unknown arguments: {' '.join(argv[1:])}")
    except ConfigError as exc:
        # refuse to serve: a client registered for a profile that does not
        # resolve must get nothing, not everything
        log(f"config error: {exc}")
        return 1
    log(f"serving vault {vault}"
        + (f", profile {prof['name']}" if prof else "")
        + (f", may write {', '.join(sorted(prof['allow_write']))}"
           if prof and prof["allow_write"] else "")
        + (", personal data masked" if pol["enabled"] else ""))

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            log(f"unparseable line ignored: {line[:120]}")
            continue
        msg_id = msg.get("id")
        method = msg.get("method", "")
        if msg_id is None:
            continue  # notification: never answered
        try:
            result = handle(cfg, pol, prof, method, msg.get("params") or {})
        except Exception as exc:  # a tool bug must not kill the transport
            log(f"error in {method}: {exc}")
            reply = {"jsonrpc": "2.0", "id": msg_id,
                     "error": {"code": -32603, "message": str(exc)}}
        else:
            if result is None:
                reply = {"jsonrpc": "2.0", "id": msg_id,
                         "error": {"code": -32601,
                                   "message": f"method not found: {method}"}}
            else:
                reply = {"jsonrpc": "2.0", "id": msg_id, "result": result}
        sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
