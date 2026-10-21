#!/usr/bin/env python3
"""Personal data masking for vault pages: e-mail addresses, phone numbers,
national id numbers and tax numbers.

Sessions are full of other people's contact details (a customer's support
mail, a user's phone in a log line, an id number in a fixture), and the
worker copies what it reads. A prompt rule alone is not enough: model
compliance varies, which the closed enum lists already taught (eight
different status values in one batch). So the rule is enforced on the
artifact, twice:

- the ingest driver runs `fix --changed` on a unit's pages after the worker
  and before verification, so nothing reaches git unmasked;
- the MCP server masks every page on the way out, which also covers pages
  written by hand or in an interactive session, outside the ingest.

Names are NOT handled here: no pattern tells a person's name from a product
or a place, and a wrong guess garbles the page. Names are a schema rule the
worker follows (see the vault's CLAUDE.md).

What is masked, and why each rule has its shape:
- e-mail: the local part becomes its first character plus "•••", the
  domain stays. Which organisation a mail belongs to is the useful part of
  a note; who exactly is not. Role and test addresses (support@, admin@,
  *.test, example.com, service accounts) stay in clear, they name no one.
- phone (Turkish numbers, mobile and landline): every digit after the
  country or trunk prefix but the last two becomes "•", separators kept, so
  two numbers in one page stay distinguishable. A bare ten digit number
  counts only on a line that talks about phones: listing and account ids
  are ten digits too.
- national id (T.C. kimlik no): eleven digits that pass the official
  checksum. One random number in a hundred passes it, so a stray id may
  get masked now and then; a leaked id number is the worse failure.
- tax number (VKN): ten digits that pass the checksum AND a tax word on the
  same line, because one random number in ten passes this checksum.

Masks use "•" (U+2022), never "*": two asterisks on one line are emphasis
in markdown and would swallow the text between them. A masked value
matches none of the patterns, so masking twice changes nothing.

Usage:
    python3 scripts/privacy.py scan <file|dir>...  list findings, exit 1 if any
    python3 scripts/privacy.py fix <file|dir>...   mask in place
    python3 scripts/privacy.py fix --changed       mask the .md files git sees
                                                   as changed (cwd = vault)
Findings are printed masked: a log line must not hold what the page may not.
Nothing under raw/ is ever touched.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load, ConfigError  # noqa: E402

DOT = "•"

# Never a person. Kept small and generic: anything vault specific belongs in
# [privacy] keep_emails / keep_domains.
ROLE_LOCAL_PARTS = {
    "abuse", "admin", "administrator", "billing", "bot", "ci", "contact",
    "demo", "dev", "devops", "do-not-reply", "donotreply", "git", "hello",
    "help", "hostmaster", "info", "infra", "it", "mailer-daemon", "no-reply",
    "noreply", "notifications", "ops", "postmaster", "root", "sales",
    "security", "support", "team", "tech", "test", "webmaster",
}
TEST_DOMAINS = ("example.com", "example.org", "example.net",
                "gserviceaccount.com", "users.noreply.github.com")
TEST_TLDS = {"test", "example", "invalid", "localhost", "local"}
# name@thing.<ext> is a file, a systemd unit or a package, not a mailbox
NON_MAIL_TLDS = {
    "css", "gif", "html", "jpeg", "jpg", "js", "json", "jsx", "lock", "log",
    "md", "mount", "mp4", "png", "py", "service", "sh", "socket", "svg",
    "target", "timer", "ts", "tsx", "txt", "webm", "webp", "yaml", "yml",
}

EMAIL_RX = re.compile(
    r"(?<![\w.+\-])([A-Za-z0-9][A-Za-z0-9._%+\-]*)@"
    r"((?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?\.)+([A-Za-z]{2,}))"
    r"(?![\w\-])")

_S = r"[ .\-]?"
# +90 / 90 / 0, then an area code (2xx-4xx landline, 5xx mobile, 8xx
# corporate) and seven digits
PHONE_PREFIXED_RX = re.compile(
    rf"(?<![\w+])(\+90|90|0){_S}\(?[2-58]\d{{2}}\)?{_S}\d{{3}}{_S}\d{{2}}{_S}\d{{2}}(?!\w)")
# a mobile number written without prefix, but with the usual grouping
PHONE_GROUPED_RX = re.compile(
    rf"(?<![\w+])\(?5\d{{2}}\)?[ .\-]\d{{3}}{_S}\d{{2}}{_S}\d{{2}}(?!\w)")
PHONE_BARE_RX = re.compile(r"(?<![\w+])5\d{9}(?!\w)")
PHONE_WORDS_RX = re.compile(
    r"telefon|\btel\b|phone|gsm|\bcep|numara|whatsapp|wa\.me|msisdn|mobile",
    re.I)
TCKN_RX = re.compile(r"(?<![\w.\-])[1-9]\d{10}(?![\w\-])")
VKN_RX = re.compile(r"(?<![\w.\-])\d{10}(?![\w\-])")
TAX_WORDS_RX = re.compile(r"vergi|\bvkn|tax|v\.k\.n", re.I)


def _csv(value):
    return [x.strip() for x in (value or "").split(",") if x.strip()]


def _digits(s):
    return re.sub(r"\D", "", s)


def policy(cfg=None):
    """The [privacy] section, shaped for mask()."""
    if cfg is None:
        cfg = load()
    p = cfg["privacy"]
    return {
        "enabled": p["mask"] == "yes",
        "keep_emails": {e.lower() for e in _csv(p["keep_emails"])},
        "keep_domains": {d.lower().lstrip("@.") for d in _csv(p["keep_domains"])},
        "keep_phones": {_digits(n)[-10:] for n in _csv(p["keep_phones"])
                        if len(_digits(n)) >= 10},
    }


def _keep_email(local, domain, tld, pol):
    addr = f"{local}@{domain}".lower()
    domain = domain.lower()
    if tld.lower() in NON_MAIL_TLDS:
        return True
    if addr in pol["keep_emails"]:
        return True
    if tld.lower() in TEST_TLDS:
        return True
    for d in tuple(pol["keep_domains"]) + TEST_DOMAINS:
        if domain == d or domain.endswith("." + d):
            return True
    base = re.sub(r"\d+$", "", local.lower().split("+", 1)[0])
    return base in ROLE_LOCAL_PARTS or base.split("-", 1)[0] in ROLE_LOCAL_PARTS


def _mask_digits(s, keep_last=2):
    """Every digit but the last keep_last becomes a dot, the rest stays."""
    total = sum(c.isdigit() for c in s)
    out, seen = [], 0
    for c in s:
        if c.isdigit():
            seen += 1
            out.append(c if seen > total - keep_last else DOT)
        else:
            out.append(c)
    return "".join(out)


def tckn_valid(s):
    d = [int(c) for c in s]
    if len(d) != 11 or d[0] == 0:
        return False
    if (sum(d[0:9:2]) * 7 - sum(d[1:8:2])) % 10 != d[9]:
        return False
    return sum(d[:10]) % 10 == d[10]


def vkn_valid(s):
    d = [int(c) for c in s]
    if len(d) != 10:
        return False
    total = 0
    for i in range(9):
        t = (d[i] + 10 - (i + 1)) % 10
        if t:
            v = (t * 2 ** (10 - (i + 1))) % 9
            total += v or 9
    return (10 - total % 10) % 10 == d[9]


def mask(text, pol):
    """(masked text, {kind: count}). Line by line, because the phone and tax
    rules look at their own line for context."""
    counts = {}

    def hit(kind):
        counts[kind] = counts.get(kind, 0) + 1

    def email(m):
        local, domain, tld = m.group(1), m.group(2), m.group(3)
        if _keep_email(local, domain, tld, pol):
            return m.group(0)
        hit("email")
        return f"{local[0]}{DOT * 3}@{domain}"

    def phone(m):
        raw = m.group(0)
        if _digits(raw)[-10:] in pol["keep_phones"]:
            return raw
        hit("phone")
        prefix = m.group(1) if m.re is PHONE_PREFIXED_RX else ""
        return prefix + _mask_digits(raw[len(prefix):])

    def tckn(m):
        if not tckn_valid(m.group(0)):
            return m.group(0)
        hit("national_id")
        return _mask_digits(m.group(0))

    def vkn(m):
        if not vkn_valid(m.group(0)):
            return m.group(0)
        hit("tax_number")
        return _mask_digits(m.group(0))

    lines = text.split("\n")
    for i, line in enumerate(lines):
        if "@" in line:
            line = EMAIL_RX.sub(email, line)
        if any(c.isdigit() for c in line):
            line = PHONE_PREFIXED_RX.sub(phone, line)
            line = PHONE_GROUPED_RX.sub(phone, line)
            if PHONE_WORDS_RX.search(line):
                line = PHONE_BARE_RX.sub(phone, line)
            line = TCKN_RX.sub(tckn, line)
            if TAX_WORDS_RX.search(line):
                line = VKN_RX.sub(vkn, line)
        lines[i] = line
    return "\n".join(lines), counts


def _under_raw(path):
    return "raw" in path.replace(os.sep, "/").split("/")


def _md_files(targets):
    for t in targets:
        if os.path.isdir(t):
            for dirpath, dirnames, filenames in os.walk(t):
                dirnames[:] = [d for d in dirnames
                               if d not in {"raw", ".git", ".a5n-logs",
                                            ".obsidian", "node_modules"}]
                for fn in sorted(filenames):
                    if fn.endswith(".md"):
                        yield os.path.join(dirpath, fn)
        elif t.endswith(".md") and os.path.isfile(t) and not _under_raw(t):
            yield t


def _changed_md():
    # quotepath=off for the same reason as ingest-verify.py: Turkish slugs
    # would otherwise arrive octal escaped and never match a real file.
    out = subprocess.run(
        ["git", "-c", "core.quotepath=off", "status", "--porcelain",
         "--untracked-files=all"],
        capture_output=True, text=True, check=True).stdout
    paths = []
    for line in out.splitlines():
        p = line[3:]
        if " -> " in p:
            p = p.split(" -> ", 1)[1]
        p = p.strip().strip('"')
        if p.endswith(".md") and os.path.isfile(p) and not _under_raw(p):
            paths.append(p)
    return paths


def _summary(counts):
    return ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))


def main(argv):
    if len(argv) < 3 or argv[1] not in ("scan", "fix"):
        sys.exit(__doc__)
    try:
        pol = policy()
    except ConfigError as exc:
        sys.stderr.write(f"A5N config error:\n{exc}\n")
        return 2
    mode, targets = argv[1], argv[2:]
    if not pol["enabled"]:
        print("privacy: [privacy] mask = no, nothing done")
        return 0
    files = _changed_md() if targets == ["--changed"] else list(_md_files(targets))

    found, changed = 0, 0
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        new, counts = mask(text, pol)
        if not counts:
            continue
        found += sum(counts.values())
        if mode == "scan":
            old_lines, new_lines = text.split("\n"), new.split("\n")
            for n, (a, b) in enumerate(zip(old_lines, new_lines), 1):
                if a != b:
                    print(f"{path}:{n}: {b.strip()[:160]}")
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            changed += 1
            print(f"privacy: masked {path} ({_summary(counts)})")
    if mode == "scan":
        print(f"privacy: {found} unmasked values in {len(files)} files scanned")
        return 1 if found else 0
    print(f"privacy: {found} values masked in {changed} of {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
