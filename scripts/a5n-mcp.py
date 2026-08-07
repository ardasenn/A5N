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

Implementation notes. Standard library only, like the rest of A5N: the MCP
stdio transport is newline delimited JSON-RPC 2.0, which needs no SDK.
stdout carries protocol messages and nothing else; diagnostics go to
stderr. The server is strictly read only and never opens anything under
raw/: transcripts are data for the ingest, not for queries, and they are
large enough to flood an agent's context.

Tools:
    vault_overview()                 orientation: namespaces, counts, patterns
    vault_search(query, project?, limit?)   ranked term search over pages
    vault_page(path)                 one page, full content
"""
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load, ConfigError  # noqa: E402

PROTOCOL_VERSION = "2025-06-18"
SKIP_DIRS = {".git", ".obsidian", ".a5n-logs", "raw", ".claude", "node_modules"}
EXCERPT_CHARS = 160
PAGE_CAP = 100 * 1024

TOOLS = [
    {
        "name": "vault_overview",
        "description": (
            "Orientation for the knowledge vault: the project namespaces with "
            "their page counts, the cross project pattern pages, and the root "
            "index. Call this first to learn what the vault knows about."
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
        "name": "vault_page",
        "description": (
            "Read one vault page in full. The path is vault relative, as "
            "returned by vault_search or vault_overview."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Vault relative path of a .md page.",
                }
            },
            "required": ["path"],
        },
    },
]


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


FM_RX = re.compile(r"^---\n(.*?)\n---", re.S)
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


def do_search(vault, query, project, limit):
    terms = [t for t in re.split(r"\W+", query.lower()) if len(t) >= 2]
    if not terms:
        return "query has no searchable terms"
    limit = max(1, min(int(limit or 10), 25))
    today = datetime.date.today()
    scored = []
    for rel, ap in iter_pages(vault, project):
        text = read_text(ap)
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


def do_page(vault, path):
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
    text = read_text(ap)
    if len(text) > PAGE_CAP:
        text = text[:PAGE_CAP] + f"\n\n[truncated at {PAGE_CAP // 1024} KB]"
    return text, None


def do_overview(vault):
    out = []
    namespaces = []
    for entry in sorted(os.listdir(vault)):
        base = os.path.join(vault, entry)
        if os.path.isdir(base) and os.path.isdir(os.path.join(base, "sources")):
            namespaces.append(entry)
    out.append(f"Namespaces ({len(namespaces)}):")
    for ns in namespaces:
        counts = []
        for cat in ("sources/sessions", "entities", "concepts", "decisions",
                    "bugs", "syntheses"):
            d = os.path.join(vault, ns, cat)
            if os.path.isdir(d):
                n = sum(1 for f in os.listdir(d) if f.endswith(".md"))
                if n:
                    counts.append(f"{cat.split('/')[-1]} {n}")
        out.append(f"- {ns}: " + (", ".join(counts) if counts else "empty"))

    pat_dir = os.path.join(vault, "patterns")
    pats = sorted(f for f in os.listdir(pat_dir) if f.endswith(".md")) \
        if os.path.isdir(pat_dir) else []
    out.append(f"\nCross project patterns ({len(pats)}):")
    out.extend(f"- patterns/{p}" for p in pats) if pats else out.append("(none yet)")

    idx = os.path.join(vault, "index.md")
    if os.path.isfile(idx):
        out.append("\nRoot index.md:\n" + read_text(idx)[:4000])
    return "\n".join(out)


def tool_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def handle(vault, method, params):
    if method == "initialize":
        return {
            "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "a5n", "version": "1.0.0"},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "vault_overview":
            return tool_result(do_overview(vault))
        if name == "vault_search":
            return tool_result(do_search(
                vault, args.get("query", ""), args.get("project", ""),
                args.get("limit", 10)))
        if name == "vault_page":
            text, err = do_page(vault, args.get("path", ""))
            return tool_result(err, True) if err else tool_result(text)
        return tool_result(f"unknown tool: {name}", True)
    return None  # unknown method


def main():
    try:
        vault = load()["vault"]["path"]
    except ConfigError as exc:
        log(f"config error: {exc}")
        return 1
    log(f"serving vault {vault}")

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
            result = handle(vault, method, msg.get("params") or {})
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
    sys.exit(main())
