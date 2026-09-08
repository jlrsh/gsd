#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["beautifulsoup4>=4.12"]
# ///
"""gsd - a minimal assignment TUI.

Aggregates assignments from any number of .ics feeds plus manually created
items, shows them as a day-grouped checklist, and sweeps checked items into a
Completed section (above the main list) on quit.

Stdlib only.  Run with `uv run gsd.py` or `python3 gsd.py`.
"""

from __future__ import annotations

import argparse
import curses
import gzip
import hashlib
import html
import json
import os
import queue
import re
import shlex
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import webbrowser
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from plugins import gradescope

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - 3.10 and older
    tomllib = None

APP = "gsd"


def detect_local_timezone() -> str | None:
    """Best-effort IANA timezone detection without freezing today's UTC offset."""
    candidates: list[str] = []
    env_tz = os.environ.get("TZ", "").lstrip(":").strip()
    if env_tz:
        candidates.append(env_tz)

    try:
        target = str(Path("/etc/localtime").resolve())
        for marker in ("/zoneinfo/", "/zoneinfo.default/"):
            if marker in target:
                candidates.append(target.split(marker, 1)[1])
                break
    except OSError:
        pass

    try:
        candidates.append(Path("/etc/timezone").read_text().strip())
    except OSError:
        pass

    for name in candidates:
        if not name or name.startswith(("/", ".")):
            continue
        try:
            ZoneInfo(name)
            return name
        except (KeyError, ValueError):
            continue
    return None


DETECTED_TIMEZONE = detect_local_timezone()
LOCAL_TIMEZONE = DETECTED_TIMEZONE
LOCAL = ZoneInfo(LOCAL_TIMEZONE) if LOCAL_TIMEZONE else datetime.now().astimezone().tzinfo


def select_local_timezone(name: str = "") -> str:
    """Select an explicit IANA zone, or auto-detect the computer's zone."""
    global LOCAL, LOCAL_TIMEZONE
    requested = name.strip()
    selected = DETECTED_TIMEZONE if requested.lower() in ("", "auto") else requested
    if selected:
        try:
            LOCAL = ZoneInfo(selected)
        except (KeyError, ValueError) as exc:
            raise ValueError(f"unknown IANA timezone: {requested}") from exc
        LOCAL_TIMEZONE = selected
    else:
        # Last-resort fallback for systems that expose only an abbreviation.
        LOCAL = datetime.now().astimezone().tzinfo
        LOCAL_TIMEZONE = None
    return LOCAL_TIMEZONE or str(LOCAL)


# --------------------------------------------------------------------------
# paths & config
# --------------------------------------------------------------------------

def _xdg(var: str, default: str) -> Path:
    root = os.environ.get(var)
    return (Path(root) if root else Path.home() / default) / APP


CONFIG_DIR = _xdg("XDG_CONFIG_HOME", ".config")
DATA_DIR = _xdg("XDG_DATA_HOME", ".local/share")
CACHE_DIR = DATA_DIR / "cache"
CONFIG_PATH = CONFIG_DIR / "config.toml"
STATE_PATH = DATA_DIR / "state.json"
PLUGIN_DIR = DATA_DIR / "plugins" / "gradescope"
GRADESCOPE_CACHE = PLUGIN_DIR / "assignments.json"
GRADESCOPE_COOKIES = PLUGIN_DIR / "cookies.txt"

DEFAULT_CONFIG = """\
# gsd configuration.  Add one [[feed]] block per .ics source.
#
# [[feed]]
# url  = "https://example.instructure.com/feeds/calendars/user_xxx.ics"
# name = "Canvas"
# enabled = true

# [plugins.gradescope]
# enabled = false
# email = "you@example.edu"
# all_terms = false
# skip_submitted = false

[settings]
horizon_days   = 120   # how far ahead to expand recurring events
retention_days = 30    # prune completed items older than this; 0 = keep forever
fetch_timeout  = 10
timezone       = "auto" # IANA name, or auto-detect this computer
"""

DEFAULTS = {"horizon_days": 120, "retention_days": 30, "fetch_timeout": 10,
            "timezone": "auto"}


@dataclass
class Feed:
    url: str
    name: str
    enabled: bool = True

    @property
    def cache_path(self) -> Path:
        digest = hashlib.sha256(self.url.encode()).hexdigest()[:24]
        return CACHE_DIR / f"{digest}.ics"


def ensure_dirs() -> None:
    for d in (CONFIG_DIR, DATA_DIR, CACHE_DIR):
        d.mkdir(parents=True, exist_ok=True)


def load_config() -> tuple[list[Feed], dict]:
    ensure_dirs()
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    settings = dict(DEFAULTS)
    feeds: list[Feed] = []
    if tomllib is None:
        return feeds, settings
    try:
        data = tomllib.loads(CONFIG_PATH.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return feeds, settings
    for key, val in (data.get("settings") or {}).items():
        if key in settings:
            if isinstance(DEFAULTS[key], int) and isinstance(val, int):
                settings[key] = val
            elif isinstance(DEFAULTS[key], str) and isinstance(val, str):
                settings[key] = val
    for entry in data.get("feed") or []:
        url = (entry.get("url") or "").strip()
        if not url:
            continue
        name = (entry.get("name") or "").strip() or _feed_name_from_url(url)
        feeds.append(Feed(url=url, name=name, enabled=entry.get("enabled") is not False))
    plugin_data = data.get("plugins") or {}
    grade = plugin_data.get("gradescope") or {}
    settings["gradescope"] = {
        "enabled": grade.get("enabled") is True,
        "email": str(grade.get("email") or "").strip(),
        "all_terms": grade.get("all_terms") is True,
        "skip_submitted": grade.get("skip_submitted") is True,
    }
    settings["resolved_timezone"] = select_local_timezone(settings["timezone"])
    return feeds, settings


def _feed_name_from_url(url: str) -> str:
    host = re.sub(r"^\w+://", "", url).split("/")[0]
    return host.split(".")[0] or "feed"


def add_feed_to_config(url: str, name: str | None) -> str:
    ensure_dirs()
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    name = name or _feed_name_from_url(url)
    block = (f"\n[[feed]]\nurl = {_toml_string(url)}\n"
             f"name = {_toml_string(name)}\nenabled = true\n")
    with CONFIG_PATH.open("a") as fh:
        fh.write(block)
    return name


def _toml_string(value: str) -> str:
    """Encode a basic TOML string using JSON's compatible escaping."""
    return json.dumps(str(value), ensure_ascii=False)


def configure_gradescope(email: str, enabled: bool = True) -> None:
    """Create/update the bundled plugin's config without touching secrets."""
    ensure_dirs()
    text = CONFIG_PATH.read_text() if CONFIG_PATH.exists() else DEFAULT_CONFIG
    header = re.search(r"(?m)^\[plugins\.gradescope\]\s*$", text)
    if header is None:
        text = text.rstrip() + ("\n\n[plugins.gradescope]\n"
                                f"enabled = {'true' if enabled else 'false'}\n"
                                f"email = {_toml_string(email)}\n"
                                "all_terms = false\nskip_submitted = false\n")
    else:
        end = re.search(r"(?m)^\[", text[header.end():])
        stop = header.end() + (end.start() if end else len(text[header.end():]))
        block = text[header.end():stop]
        block = _set_toml_key(block, "enabled", "true" if enabled else "false")
        block = _set_toml_key(block, "email", _toml_string(email))
        text = text[:header.end()] + block + text[stop:]
    _write_config(text)


def configure_timezone(name: str) -> str:
    """Validate and persist an IANA timezone, or `auto` for system detection."""
    value = "auto" if name.strip().lower() in ("", "auto") else name.strip()
    resolved = select_local_timezone(value)
    ensure_dirs()
    text = CONFIG_PATH.read_text() if CONFIG_PATH.exists() else DEFAULT_CONFIG
    header = re.search(r"(?m)^\[settings\]\s*$", text)
    if header is None:
        text = f"[settings]\ntimezone = {_toml_string(value)}\n\n" + text
    else:
        next_header = re.search(r"(?m)^\s*\[", text[header.end():])
        stop = header.end() + next_header.start() if next_header else len(text)
        block = _set_toml_key(text[header.end():stop], "timezone", _toml_string(value))
        text = text[:header.end()] + block + text[stop:]
    _write_config(text)
    return resolved


def _set_toml_key(block: str, key: str, value: str) -> str:
    pattern = re.compile(
        rf"(?m)^(\s*{re.escape(key)}\s*=\s*)[^#\n]*?(\s*(?:#.*)?)$")
    if pattern.search(block):
        return pattern.sub(lambda m: m.group(1) + value + m.group(2), block, count=1)
    return block.rstrip() + f"\n{key} = {value}\n"


def _write_config(text: str) -> None:
    ensure_dirs()
    tmp = CONFIG_PATH.with_suffix(".toml.tmp")
    tmp.write_text(text if text.endswith("\n") else text + "\n")
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass


def set_source_enabled(kind: str, identifier: str, enabled: bool) -> None:
    """Toggle one source while preserving the rest of the hand-written TOML."""
    text = CONFIG_PATH.read_text()
    if kind == "gradescope":
        email = (load_config()[1].get("gradescope") or {}).get("email", "")
        configure_gradescope(email, enabled)
        return
    starts = list(re.finditer(r"(?m)^\[\[feed\]\]\s*$", text))
    for idx, start in enumerate(starts):
        next_header = re.search(r"(?m)^\s*\[", text[start.end():])
        stop = start.end() + next_header.start() if next_header else len(text)
        block = text[start.end():stop]
        url_match = re.search(r'(?m)^\s*url\s*=\s*(["\'])(.*?)\1\s*(?:#.*)?$', block)
        if url_match and url_match.group(2) == identifier:
            block = _set_toml_key(block, "enabled", "true" if enabled else "false")
            _write_config(text[:start.end()] + block + text[stop:])
            return
    raise ValueError("calendar feed was not found in config")


def edit_config() -> int:
    ensure_dirs()
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    command = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
    return subprocess.run([*shlex.split(command), str(CONFIG_PATH)]).returncode


# --------------------------------------------------------------------------
# ics parsing
# --------------------------------------------------------------------------

_TZ_CACHE: dict[str, object] = {}
URL_RE = re.compile(r'https?://[^\s<>"\'\)\]]+')
WEEKDAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}
_ESCAPES = {"n": "\n", "N": "\n", ",": ",", ";": ";", "\\": "\\"}


# Windows / Exchange TZIDs that zoneinfo rejects outright.
WINDOWS_TZ = {
    "eastern standard time": "America/New_York",
    "central standard time": "America/Chicago",
    "mountain standard time": "America/Denver",
    "pacific standard time": "America/Los_Angeles",
    "us mountain standard time": "America/Phoenix",
    "alaskan standard time": "America/Anchorage",
    "hawaiian standard time": "Pacific/Honolulu",
    "gmt standard time": "Europe/London",
    "w. europe standard time": "Europe/Berlin",
    "central europe standard time": "Europe/Budapest",
    "romance standard time": "Europe/Paris",
    "india standard time": "Asia/Kolkata",
    "china standard time": "Asia/Shanghai",
    "tokyo standard time": "Asia/Tokyo",
    "aus eastern standard time": "Australia/Sydney",
}


def tz_for(tzid: str | None):
    """Resolve a TZID, falling back to local time for names zoneinfo rejects.

    Handles bare IANA names, Mozilla-style ``/mozilla.org/2007.../America/X``
    prefixes, and Windows display names emitted by Exchange/Outlook feeds.
    """
    if not tzid:
        return LOCAL
    tzid = tzid.strip().strip('"')
    if tzid in _TZ_CACHE:
        return _TZ_CACHE[tzid]

    candidates = [tzid]
    if tzid.startswith("/"):
        # /mozilla.org/20070129_1/America/New_York -> America/New_York
        parts = [p for p in tzid.split("/") if p]
        for i in range(len(parts)):
            candidates.append("/".join(parts[i:]))
    mapped = WINDOWS_TZ.get(tzid.lower())
    if mapped:
        candidates.insert(0, mapped)

    tz = LOCAL
    for candidate in candidates:
        try:
            tz = ZoneInfo(candidate)
            break
        except Exception:
            continue
    _TZ_CACHE[tzid] = tz
    return tz


def decode_ics(raw: bytes) -> str:
    """Unfold at the byte level, then decode.

    RFC 5545 folds on octets, so a multi-byte character can be split across a
    fold; decoding first would corrupt it (or raise).  utf-8-sig strips a BOM,
    which would otherwise stop BEGIN:VCALENDAR from matching.
    """
    for fold in (b"\r\n ", b"\r\n\t", b"\n ", b"\n\t", b"\r ", b"\r\t"):
        raw = raw.replace(fold, b"")
    return raw.decode("utf-8-sig", errors="replace")


def looks_like_calendar(text: str) -> bool:
    """Reject login pages and error HTML before they overwrite a good cache."""
    head = text.lstrip()[:400].lower()
    if head.startswith(("<!doctype", "<html", "<?xml")):
        return False
    return "begin:vcalendar" in text[:4096].lower()


_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


def clean_text(value: str) -> str:
    """Make a value safe to hand to curses: no NULs, tabs, or newlines."""
    value = html.unescape(value)
    value = _CONTROL_RE.sub("", value.replace("\t", " ").replace("\n", " "))
    return " ".join(value.split())


def unfold(text: str) -> list[str]:
    """Line unfolding for already-decoded text (used by tests and file input)."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines: list[str] = []
    for raw in text.split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    return lines
def _split_semis(head: str) -> list[str]:
    """Split a property head on ';', respecting double-quoted parameter values."""
    parts: list[str] = []
    buf: list[str] = []
    quoted = False
    for ch in head:
        if ch == '"':
            quoted = not quoted
            buf.append(ch)
        elif ch == ";" and not quoted:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    parts.append("".join(buf))
    return parts


def split_line(line: str):
    """NAME;PARAM=VAL:VALUE -> (name, params, value), or None if malformed."""
    quoted = False
    idx = -1
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ":" and not quoted:
            idx = i
            break
    if idx < 0:
        return None
    head, value = line[:idx], line[idx + 1:]
    parts = _split_semis(head)
    name = parts[0].strip().upper()
    if not name:
        return None
    params: dict[str, str] = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.strip().upper()] = v.strip().strip('"')
    return name, params, value


def unescape(value: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            out.append(_ESCAPES.get(value[i + 1], value[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def parse_dt(value: str, params: dict[str, str]):
    """Return (datetime, all_day).  Raises ValueError on unparseable input."""
    v = value.strip()
    if not v:
        raise ValueError("empty datetime")
    if params.get("VALUE") == "DATE" or (len(v) == 8 and v.isdigit()):
        d = datetime.strptime(v[:8], "%Y%m%d")
        return d.replace(tzinfo=LOCAL), True
    if v.endswith("Z"):
        d = datetime.strptime(v[:-1], "%Y%m%dT%H%M%S")
        return d.replace(tzinfo=timezone.utc), False
    d = datetime.strptime(v, "%Y%m%dT%H%M%S")
    return d.replace(tzinfo=tz_for(params.get("TZID"))), False


def parse_components(text: str) -> list[dict]:
    """Extract VEVENT / VTODO blocks as {name: [(params, value), ...]} dicts.

    Properties are harvested only at the depth of the VEVENT/VTODO itself, so a
    nested VALARM's DESCRIPTION/SUMMARY cannot masquerade as the event's, and a
    VTIMEZONE's DTSTART/RRULE never becomes an item.
    """
    stack: list[str] = []
    comps: list[dict] = []
    current: dict | None = None
    depth_of_current = -1

    for line in unfold(text):
        if not line.strip():
            continue
        parsed = split_line(line)
        if parsed is None:
            continue
        name, params, value = parsed

        if name == "BEGIN":
            kind = value.strip().upper()
            stack.append(kind)
            if kind in ("VEVENT", "VTODO") and current is None:
                current = {"_kind": kind}
                depth_of_current = len(stack)
            continue

        if name == "END":
            kind = value.strip().upper()
            if current is not None and len(stack) == depth_of_current and kind == current["_kind"]:
                comps.append(current)
                current = None
                depth_of_current = -1
            if stack and stack[-1] == kind:
                stack.pop()
            continue

        # Only collect properties belonging directly to the VEVENT/VTODO.
        if current is None or len(stack) != depth_of_current:
            continue
        current.setdefault(name, []).append((params, value))

    return comps


def first(comp: dict, name: str) -> tuple[dict, str] | None:
    vals = comp.get(name)
    return vals[0] if vals else None


def extract_link(comp: dict) -> str | None:
    """First usable link on the component.

    Order matters: Canvas puts the assignment URL in DESCRIPTION, Outlook in
    X-ALT-DESC, and conferencing links land in LOCATION.
    """
    got = first(comp, "URL")
    if got:
        candidate = clean_text(unescape(got[1]))
        if candidate.startswith(("http://", "https://")):
            return candidate
    for name in ("DESCRIPTION", "X-ALT-DESC", "LOCATION", "COMMENT", "ATTACH"):
        for _params, raw in comp.get(name, []):
            match = URL_RE.search(_deep_unescape(unescape(raw)))
            if match:
                return match.group(0).rstrip(".,;:)]>\"'")
    return None


def _deep_unescape(text: str) -> str:
    """Undo HTML entities, repeating for producers that double-encode.

    Canvas emits `&amp;amp;` inside assignment URLs; a single pass leaves
    `&amp;` and the link opens to an error page.
    """
    for _ in range(3):
        nxt = html.unescape(text)
        if nxt == text:
            break
        text = nxt
    return text


# --------------------------------------------------------------------------
# recurrence
# --------------------------------------------------------------------------

def parse_rrule(value: str) -> dict[str, str]:
    rule: dict[str, str] = {}
    for part in value.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            rule[k.strip().upper()] = v.strip()
    return rule


def _add_months(d: datetime, n: int) -> datetime | None:
    y = d.year + (d.month - 1 + n) // 12
    m = (d.month - 1 + n) % 12 + 1
    try:
        return d.replace(year=y, month=m)
    except ValueError:  # e.g. Jan 31 -> Feb 31
        return None


def _nth_weekday(year: int, month: int, weekday: int, nth: int) -> date | None:
    """nth (1-based, negative counts from the end) `weekday` in a month."""
    first_day = date(year, month, 1)
    offset = (weekday - first_day.weekday()) % 7
    days = []
    d = first_day + timedelta(days=offset)
    while d.month == month:
        days.append(d)
        d += timedelta(days=7)
    if nth > 0:
        return days[nth - 1] if nth <= len(days) else None
    return days[nth] if -nth <= len(days) else None


def expand_rrule(dtstart: datetime, rule: dict[str, str],
                 lo: datetime, hi: datetime, cap: int = 500) -> list[datetime]:
    """Expand DAILY/WEEKLY/MONTHLY rules, emitting instances within [lo, hi].

    COUNT is tallied from DTSTART (not from `lo`) so a bounded series does not
    over-generate.  Anything using rule parts we do not implement degrades to
    the single DTSTART occurrence -- a missing series is safer than a
    plausible-but-wrong one.
    """
    freq = rule.get("FREQ", "").upper()
    if freq not in ("DAILY", "WEEKLY", "MONTHLY"):
        return [dtstart]
    for unsupported in ("BYSETPOS", "BYWEEKNO", "BYYEARDAY", "BYMONTH", "BYHOUR"):
        if rule.get(unsupported):
            return [dtstart]
    try:
        interval = max(1, int(rule.get("INTERVAL", "1")))
    except ValueError:
        interval = 1
    try:
        count = int(rule["COUNT"]) if rule.get("COUNT") else None
    except ValueError:
        count = None
    until = None
    if rule.get("UNTIL"):
        try:
            until, _ = parse_dt(rule["UNTIL"], {})
        except ValueError:
            until = None

    raw_byday = [t.strip().upper() for t in rule.get("BYDAY", "").split(",") if t.strip()]
    byday = [WEEKDAYS[t[-2:]] for t in raw_byday if t[-2:] in WEEKDAYS]
    nth_byday: list[tuple[int, int]] = []
    for tok in raw_byday:
        m = re.fullmatch(r"([+-]?\d+)(MO|TU|WE|TH|FR|SA|SU)", tok)
        if m:
            nth_byday.append((int(m.group(1)), WEEKDAYS[m.group(2)]))
    try:
        bymonthday = [int(x) for x in rule.get("BYMONTHDAY", "").split(",") if x.strip()]
    except ValueError:
        bymonthday = []

    out: list[datetime] = []
    emitted = 0
    clock = dtstart.timetz()

    def emit(occ: datetime) -> bool:
        """Record an occurrence.  Returns False when iteration should stop."""
        nonlocal emitted
        if until and occ > until:
            return False
        emitted += 1
        if count is not None and emitted > count:
            return False
        if occ > hi:
            return False
        if occ >= lo:
            out.append(occ)
        return len(out) < cap

    if freq == "WEEKLY" and byday:
        # DTSTART is always the first instance, even if its weekday is not in BYDAY.
        if dtstart.weekday() not in byday and not emit(dtstart):
            return out
        week0 = dtstart - timedelta(days=dtstart.weekday())
        for w in range(0, 600):
            week = week0 + timedelta(weeks=w * interval)
            if week > hi + timedelta(days=7):
                break
            for wd in sorted(byday):
                occ = week + timedelta(days=wd)
                if occ < dtstart:
                    continue
                if not emit(occ):
                    return out
        return out

    if freq == "MONTHLY" and (bymonthday or nth_byday):
        for i in range(0, 400):
            anchor = _add_months(dtstart.replace(day=1), interval * i)
            if anchor is None:
                continue
            if datetime.combine(date(anchor.year, anchor.month, 1), clock) > hi:
                break
            days: list[date] = []
            for md in bymonthday:
                try:
                    days.append(date(anchor.year, anchor.month, md) if md > 0
                                else _month_end(anchor.year, anchor.month, md))
                except ValueError:
                    continue
            for nth, wd in nth_byday:
                got = _nth_weekday(anchor.year, anchor.month, wd, nth)
                if got:
                    days.append(got)
            for d in sorted(x for x in days if x):
                occ = datetime.combine(d, clock)
                if occ < dtstart:
                    continue
                if not emit(occ):
                    return out
        return out

    occ: datetime | None = dtstart
    for i in range(0, 2000):
        if occ is not None and not emit(occ):
            break
        step = interval * (i + 1)
        if freq == "DAILY":
            occ = dtstart + timedelta(days=step)
        elif freq == "WEEKLY":
            occ = dtstart + timedelta(weeks=step)
        else:
            occ = _add_months(dtstart, step)
        if occ is not None and occ > hi:
            break
    return out


def _month_end(year: int, month: int, offset: int) -> date | None:
    """BYMONTHDAY=-1 -> last day of month, -2 -> second to last, ..."""
    if month == 12:
        nxt = date(year + 1, 1, 1)
    else:
        nxt = date(year, month + 1, 1)
    d = nxt + timedelta(days=offset)
    return d if d.month == month else None


# --------------------------------------------------------------------------
# items
# --------------------------------------------------------------------------

@dataclass
class Item:
    key: str
    title: str
    due: datetime | None            # None for an undated VTODO
    all_day: bool
    link: str | None = None
    source: str = "manual"
    manual: bool = False
    checked: bool = False
    completed_at: str | None = None

    @property
    def local_due(self) -> datetime | None:
        return self.due.astimezone(LOCAL) if self.due else None

    @property
    def day(self) -> date | None:
        due = self.local_due
        return due.date() if due else None

    @property
    def sort_key(self) -> tuple:
        due = self.local_due
        if due is None:
            return (1, datetime.max.replace(tzinfo=LOCAL), self.title.lower())
        return (0, due, self.title.lower())

    def time_label(self) -> str:
        due = self.local_due
        if due is None or self.all_day:
            return ""
        return f"{due:%H:%M}"

    def to_json(self) -> dict:
        return {
            "key": self.key,
            "title": self.title,
            "due": self.due.isoformat() if self.due else None,
            "all_day": self.all_day,
            "link": self.link,
            "source": self.source,
            "manual": self.manual,
            "completed_at": self.completed_at,
        }

    @staticmethod
    def from_json(d: dict) -> "Item | None":
        raw = d.get("due")
        due = None
        if raw:
            try:
                due = datetime.fromisoformat(raw)
            except ValueError:
                return None
            if due.tzinfo is None:
                due = due.replace(tzinfo=LOCAL)
        return Item(
            key=d.get("key") or uuid.uuid4().hex,
            title=d.get("title") or "(untitled)",
            due=due,
            all_day=bool(d.get("all_day")),
            link=d.get("link"),
            source=d.get("source") or "manual",
            manual=bool(d.get("manual")),
            completed_at=d.get("completed_at"),
        )


def item_key(feed_url: str, uid: str, occurrence: datetime | None) -> str:
    """Stable identity for an occurrence.

    The occurrence date is part of the key: a weekly lecture shares one UID
    across the whole semester, so a UID-only key would tick off every instance
    at once.  The feed URL is excluded so the same event subscribed through two
    feeds collapses to one item.
    """
    stamp = f"{occurrence.astimezone(timezone.utc):%Y%m%d}" if occurrence else "nodate"
    return hashlib.sha1(f"{uid}\x00{stamp}".encode()).hexdigest()[:20]


def _component_dt(comp: dict):
    """Preferred timestamp for a component: DUE for VTODO, else DTSTART."""
    order = ("DUE", "DTSTART") if comp.get("_kind") == "VTODO" else ("DTSTART", "DUE")
    for name in order:
        got = first(comp, name)
        if got:
            try:
                return parse_dt(got[1], got[0])
            except ValueError:
                continue
    return None


def _date_set(comp: dict, name: str) -> list[datetime]:
    """Parse a comma-separated, possibly repeated date property (EXDATE/RDATE)."""
    out: list[datetime] = []
    for params, raw in comp.get(name, []):
        for piece in raw.split(","):
            try:
                dt, _ = parse_dt(piece, params)
            except ValueError:
                continue
            out.append(dt)
    return out


def _uid_of(comp: dict, fallback: str) -> str:
    got = first(comp, "UID")
    uid = clean_text(unescape(got[1])) if got else ""
    return uid or hashlib.sha1(fallback.encode()).hexdigest()


def _is_cancelled(comp: dict) -> bool:
    got = first(comp, "STATUS")
    return bool(got) and got[1].strip().upper() == "CANCELLED"


def items_from_ics(text: str, feed: Feed, horizon_days: int) -> list[Item]:
    """Turn one .ics document into a flat list of Items."""
    comps = parse_components(text)
    now = datetime.now(LOCAL)
    hi = now + timedelta(days=horizon_days)
    # Recurring series are expanded over a short lookback; one-off events get a
    # wide one so a long-overdue assignment never silently disappears.
    recur_lo = now - timedelta(days=30)
    single_lo = now - timedelta(days=365)

    overrides: dict[tuple[str, date], dict] = {}
    bases: list[dict] = []
    for comp in comps:
        rid = first(comp, "RECURRENCE-ID")
        if rid:
            try:
                dt, _ = parse_dt(rid[1], rid[0])
            except ValueError:
                bases.append(comp)
                continue
            overrides[(_uid_of(comp, ""), dt.astimezone(LOCAL).date())] = comp
        else:
            bases.append(comp)

    items: list[Item] = []
    seen: set[str] = set()

    for comp in bases:
        if _is_cancelled(comp):
            continue
        summ = first(comp, "SUMMARY")
        title = clean_text(unescape(summ[1])) if summ else ""
        title = title or "(untitled)"
        uid = _uid_of(comp, f"{title}{first(comp, 'DTSTART')}")

        got = _component_dt(comp)
        if got is None:
            # An undated VTODO is still a real task; park it in its own group.
            if comp.get("_kind") == "VTODO":
                key = item_key(feed.url, uid, None)
                if key not in seen:
                    seen.add(key)
                    items.append(Item(key=key, title=title, due=None, all_day=True,
                                      link=extract_link(comp), source=feed.name))
            continue
        dtstart, all_day = got

        rrule_prop = first(comp, "RRULE")
        if rrule_prop:
            occurrences = expand_rrule(dtstart, parse_rrule(rrule_prop[1]), recur_lo, hi)
        else:
            occurrences = [dtstart] if single_lo <= dtstart <= hi else []
        for extra in _date_set(comp, "RDATE"):
            if single_lo <= extra <= hi:
                occurrences.append(extra)

        skip = {d.astimezone(LOCAL).date() for d in _date_set(comp, "EXDATE")}

        for occ in occurrences:
            occ_day = occ.astimezone(LOCAL).date()
            if occ_day in skip:
                continue
            # Key on the ORIGINAL occurrence date so a check survives the event
            # being moved by a RECURRENCE-ID override.
            key = item_key(feed.url, uid, occ)
            if key in seen:
                continue
            src = overrides.get((uid, occ_day))
            shown_dt, shown_all_day = occ, all_day
            shown_title, shown_comp = title, comp
            if src is not None:
                if _is_cancelled(src):
                    continue
                moved = _component_dt(src)
                if moved is not None:
                    shown_dt, shown_all_day = moved
                osumm = first(src, "SUMMARY")
                if osumm:
                    shown_title = clean_text(unescape(osumm[1])) or title
                shown_comp = src
                if extract_link(src) is None:
                    shown_comp = comp          # inherit the series' link
            seen.add(key)
            items.append(Item(
                key=key,
                title=shown_title,
                due=shown_dt,
                all_day=shown_all_day,
                link=extract_link(shown_comp),
                source=feed.name,
            ))
    return items


# --------------------------------------------------------------------------
# fetch
# --------------------------------------------------------------------------

@dataclass
class FeedStatus:
    name: str
    ok: bool = False
    error: str | None = None
    cached_at: float | None = None
    pending: bool = True


def fetch_text(url: str, timeout: int) -> str:
    """Fetch one feed and decode it.  Raises on transport or content failure."""
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    elif url.startswith("webcals://"):
        url = "https://" + url[len("webcals://"):]

    if not re.match(r"^\w+://", url):
        raw = Path(url).expanduser().read_bytes()
    else:
        req = urllib.request.Request(url, headers={
            # Plain Python-urllib/x.y gets 403'd by the CDNs in front of some LMSes.
            "User-Agent": f"{APP}/1.0",
            "Accept": "text/calendar, text/plain, */*",
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    if raw[:2] == b"\x1f\x8b":               # some servers gzip regardless
        raw = gzip.decompress(raw)

    text = decode_ics(raw)
    if not looks_like_calendar(text):
        raise ValueError("not a calendar (login page?)")
    return text


GRADESCOPE_SOURCE = "plugin:gradescope"


def gradescope_items(rows: list[dict]) -> list[Item]:
    """Adapt scraped records directly into gsd's model (there is no ICS hop)."""
    items = []
    for row in rows:
        try:
            due = datetime.fromisoformat(str(row["due_iso"]).replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if due.tzinfo is None:
            due = due.replace(tzinfo=LOCAL)
        identity = f"{row.get('course_id', '')}:{row.get('key', row.get('title', ''))}"
        key = hashlib.sha1(f"gradescope\x00{identity}".encode()).hexdigest()[:20]
        title = clean_text(f"{row.get('course', '')} — {row.get('title', '(untitled)')}")
        items.append(Item(key=key, title=title, due=due, all_day=False,
                          link=row.get("url"), source="Gradescope"))
    return items


def start_fetches(feeds: list[Feed], timeout: int, grade_config: dict | None = None,
                  horizon_days: int = 120) -> queue.Queue:
    """Kick off one daemon thread per active source."""
    q: queue.Queue = queue.Queue()

    def work(feed: Feed) -> None:
        try:
            text = fetch_text(feed.url, timeout)
        except Exception as exc:              # network, DNS, TLS, bad path, HTML
            q.put((feed, None, _short_error(exc)))
            return
        try:
            feed.cache_path.write_text(text)
            os.chmod(feed.cache_path, 0o600)
        except OSError:
            pass
        q.put((feed, text, None))

    for feed in (source for source in feeds if source.enabled):
        threading.Thread(target=work, args=(feed,), daemon=True).start()

    if grade_config and grade_config.get("enabled"):
        def work_gradescope() -> None:
            try:
                rows = gradescope.fetch(grade_config, GRADESCOPE_COOKIES, timeout,
                                         horizon_days)
                gradescope.write_cache(GRADESCOPE_CACHE, rows)
            except Exception as exc:
                q.put((GRADESCOPE_SOURCE, None, _short_error(exc)))
                return
            q.put((GRADESCOPE_SOURCE, rows, None))
        threading.Thread(target=work_gradescope, daemon=True).start()
    return q


def _short_error(exc: Exception) -> str:
    """A message safe to render: never echo the URL, it can carry a token."""
    if isinstance(exc, urllib.error.HTTPError):
        return f"HTTP {exc.code}"
    if isinstance(exc, urllib.error.URLError):
        return str(getattr(exc, "reason", "unreachable"))[:40]
    if isinstance(exc, ValueError):
        return str(exc)[:40]
    if isinstance(exc, gradescope.GradescopeError):
        return str(exc)[:60]
    return type(exc).__name__[:40]


def read_cache(feed: Feed) -> tuple[str | None, float | None]:
    try:
        stat = feed.cache_path.stat()
        return feed.cache_path.read_text(errors="replace"), stat.st_mtime
    except OSError:
        return None, None


# --------------------------------------------------------------------------
# store
# --------------------------------------------------------------------------

EMPTY_STATE = {"version": 1, "manual": [], "completed": {}, "checked": []}


def load_state() -> dict:
    """Load state, quarantining a corrupt file rather than refusing to start."""
    if not STATE_PATH.exists():
        return dict(EMPTY_STATE, manual=[], completed={}, checked=[])
    try:
        data = json.loads(STATE_PATH.read_text())
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except (OSError, ValueError):
        try:
            STATE_PATH.replace(STATE_PATH.with_suffix(".json.bad"))
        except OSError:
            pass
        return dict(EMPTY_STATE, manual=[], completed={}, checked=[])
    data.setdefault("version", 1)
    data.setdefault("manual", [])
    data.setdefault("completed", {})
    data.setdefault("checked", [])
    return data


def save_state(state: dict) -> None:
    ensure_dirs()
    state["version"] = 1
    tmp = STATE_PATH.with_suffix(".json.tmp")
    with tmp.open("w") as fh:
        json.dump(state, fh, indent=1)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, STATE_PATH)
    try:
        os.chmod(STATE_PATH, 0o600)
    except OSError:
        pass


def prune_completed(completed: dict, retention_days: int) -> dict:
    if retention_days <= 0:
        return completed
    cutoff = datetime.now(LOCAL) - timedelta(days=retention_days)
    kept = {}
    for key, snap in completed.items():
        stamp = snap.get("completed_at")
        if not stamp:
            kept[key] = snap
            continue
        try:
            when = datetime.fromisoformat(stamp)
        except ValueError:
            kept[key] = snap
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=LOCAL)
        if when >= cutoff:
            kept[key] = snap
    return kept


# --------------------------------------------------------------------------
# model / layout
# --------------------------------------------------------------------------

@dataclass
class Row:
    kind: str                    # "item" | "header" | "blank" | "rule"
    text: str = ""
    item: Item | None = None
    style: str = ""              # "section" | "day" | "overdue"


def group_by_day(items: list[Item]) -> list[tuple[date, list[Item]]]:
    """Group dated items by local day.  Undated items are the caller's problem."""
    buckets: dict[date, list[Item]] = {}
    for it in items:
        if it.day is None:
            continue
        buckets.setdefault(it.day, []).append(it)
    for lst in buckets.values():
        lst.sort(key=lambda i: i.sort_key)
    return sorted(buckets.items())


def day_label(d: date, today: date) -> str:
    delta = (d - today).days
    if delta == 0:
        return f"Today · {d:%a %b %-d}"
    if delta == 1:
        return f"Tomorrow · {d:%a %b %-d}"
    if d.year != today.year:
        return f"{d:%a %b %-d, %Y}"
    return f"{d:%a %b %-d}"


def build_rows(completed: list[Item], main: list[Item]) -> tuple[list[Row], int]:
    """Flat row list.  Completed first (above the fold), then the main list.

    Returns (rows, main_start) where main_start is the row index the viewport is
    parked at on launch, so Completed sits just off-screen above.
    """
    today = date.today()
    rows: list[Row] = []

    if completed:
        rows.append(Row("header", "Completed", style="section"))
        groups = group_by_day(completed)
        undated_done = [it for it in completed if it.day is None]
        for day, items in groups:
            rows.append(Row("blank"))
            rows.append(Row("header", day_label(day, today), style="day"))
            rows.extend(Row("item", item=it) for it in items)
        if undated_done:
            rows.append(Row("blank"))
            rows.append(Row("header", "No date", style="day"))
            rows.extend(Row("item", item=it) for it in undated_done)
        rows.append(Row("blank"))
        rows.append(Row("rule"))
        rows.append(Row("blank"))

    main_start = len(rows)

    overdue = [it for it in main if it.day is not None and it.day < today]
    upcoming = [it for it in main if it.day is not None and it.day >= today]
    undated = [it for it in main if it.day is None]

    blocks: list[tuple[str, list[Item], str]] = []
    if overdue:
        overdue.sort(key=lambda i: i.sort_key)
        blocks.append(("Overdue", overdue, "overdue"))
    for day, items in group_by_day(upcoming):
        blocks.append((day_label(day, today), items, "day"))
    if undated:
        undated.sort(key=lambda i: i.title.lower())
        blocks.append(("No date", undated, "day"))

    for i, (label, items, style) in enumerate(blocks):
        if i:
            rows.append(Row("blank"))
        rows.append(Row("header", label, style=style))
        rows.extend(Row("item", item=it) for it in items)

    if not blocks:
        rows.append(Row("header", "Nothing due", style="day"))

    return rows, main_start


# --------------------------------------------------------------------------
# text helpers
# --------------------------------------------------------------------------

def cwidth(ch: str) -> int:
    """Columns a single character occupies on screen."""
    if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


def dwidth(s: str) -> int:
    return sum(cwidth(c) for c in s)


def dtrim(s: str, limit: int) -> str:
    if limit <= 0:
        return ""
    if dwidth(s) <= limit:
        return s
    out: list[str] = []
    used = 0
    for ch in s:
        w = cwidth(ch)
        if used + w > limit - 1:
            break
        out.append(ch)
        used += w
    return "".join(out) + "…"


def rel_time(ts: float | None) -> str:
    if not ts:
        return "never"
    secs = max(0, int(time.time() - ts))
    if secs < 60:
        return "just now"
    if secs < 3600:
        return f"{secs // 60}m ago"
    if secs < 86400:
        return f"{secs // 3600}h ago"
    return f"{secs // 86400}d ago"


# --------------------------------------------------------------------------
# manual entry parsing
# --------------------------------------------------------------------------

_WEEKDAY_NAMES = [
    ("mon", "monday"), ("tue", "tues", "tuesday"), ("wed", "weds", "wednesday"),
    ("thu", "thur", "thurs", "thursday"), ("fri", "friday"),
    ("sat", "saturday"), ("sun", "sunday"),
]
_DATE_FORMATS = [
    ("%Y-%m-%d", True), ("%Y/%m/%d", True), ("%m/%d/%Y", True), ("%m/%d/%y", True),
    ("%m/%d", False), ("%m-%d", False), ("%b %d", False), ("%d %b", False),
    ("%B %d", False),
]


def parse_time_token(tok: str) -> tuple[int, int] | None:
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?", tok.strip().lower())
    if not m:
        return None
    hour = int(m.group(1))
    minute = int(m.group(2) or 0)
    ampm = m.group(3)
    if ampm:
        if hour < 1 or hour > 12:
            return None
        hour = hour % 12 + (12 if ampm == "pm" else 0)
    elif m.group(2) is None:
        return None                       # a bare number is a day, not a time
    if hour > 23 or minute > 59:
        return None
    return hour, minute


def parse_when(text: str) -> tuple[datetime, bool] | None:
    """Parse a manual due date, with an optional trailing time.

    Accepts: today, tomorrow, weekday names, +3, 9/12, 2026-09-12, "Sep 12",
    each optionally followed by a time such as 17:00, 5pm or 11:59pm.
    """
    raw = " ".join(text.strip().split())
    today = date.today()
    if not raw:
        return datetime.combine(today, datetime.min.time(), LOCAL), True

    clock: tuple[int, int] | None = None
    tokens = raw.split(" ")
    if len(tokens) > 1:
        maybe = parse_time_token(tokens[-1])
        if maybe:
            clock = maybe
            tokens = tokens[:-1]
    body = " ".join(tokens).lower()

    day: date | None = None
    if body in ("", "today", "tod"):
        day = today
    elif body in ("tomorrow", "tmr", "tom"):
        day = today + timedelta(days=1)
    elif re.fullmatch(r"\+\d+", body):
        day = today + timedelta(days=int(body[1:]))
    else:
        for idx, names in enumerate(_WEEKDAY_NAMES):
            if body in names:
                ahead = (idx - today.weekday()) % 7 or 7
                day = today + timedelta(days=ahead)
                break
    if day is None:
        for fmt, has_year in _DATE_FORMATS:
            # Pin the year explicitly: a year-less strptime is ambiguous and
            # its default changes in Python 3.15.
            if has_year:
                try:
                    day = datetime.strptime(body, fmt).date()
                except ValueError:
                    continue
                break
            # Year-less input means the next such date.  Trying successive
            # years also resolves 29 Feb onto the next leap year.
            for bump in range(0, 5):
                try:
                    candidate = datetime.strptime(
                        f"{body} {today.year + bump}", f"{fmt} %Y").date()
                except ValueError:
                    continue
                if candidate >= today:
                    day = candidate
                    break
            if day is not None:
                break
    if day is None:
        return None

    if clock is None:
        return datetime.combine(day, datetime.min.time(), LOCAL), True
    return datetime.combine(day, datetime.min.time().replace(
        hour=clock[0], minute=clock[1]), LOCAL), False


# --------------------------------------------------------------------------
# ui
# --------------------------------------------------------------------------

HELP_LINES = [
    ("j / k, ↓ / ↑", "move between assignments"),
    ("g / G", "jump to first / last"),
    ("space", "check or uncheck"),
    ("enter", "open the event's first link"),
    ("a", "add an assignment by hand"),
    ("e / d", "edit / delete a manual assignment"),
    ("r", "refresh all feeds"),
    ("c", "enable or disable sources"),
    ("?", "this help"),
    ("q", "quit, filing checked items under Completed"),
]


class App:
    def __init__(self, stdscr, feeds: list[Feed], settings: dict, state: dict):
        self.stdscr = stdscr
        self.all_feeds = feeds
        self.feeds = [feed for feed in feeds if feed.enabled]
        self.settings = settings
        self.grade_config = settings.get("gradescope") or {"enabled": False, "email": ""}
        self.state = state

        self.completed: dict[str, dict] = state["completed"]
        self.checked: set[str] = set(self.completed) | set(state.get("checked", []))
        self.manual: list[Item] = [
            it for it in (Item.from_json(d) for d in state.get("manual", [])) if it
        ]
        for it in self.manual:
            it.manual = True

        self.feed_items: dict[str, list[Item]] = {}
        self.status: dict[str, FeedStatus] = {
            f.url: FeedStatus(name=f.name) for f in self.feeds
        }
        if self.grade_config.get("enabled"):
            self.status[GRADESCOPE_SOURCE] = FeedStatus(name="Gradescope")
        self.queue: queue.Queue | None = None
        self.message = ""
        self.message_until = 0.0

        self.rows: list[Row] = []
        self.main_start = 0
        self.cursor = 0
        self.scroll = 0
        self.dirty = True

    # -- data ------------------------------------------------------------

    def load_caches(self) -> None:
        for feed in self.feeds:
            text, mtime = read_cache(feed)
            if text is None:
                continue
            try:
                self.feed_items[feed.url] = items_from_ics(
                    text, feed, self.settings["horizon_days"])
            except Exception:
                self.feed_items[feed.url] = []
            self.status[feed.url].cached_at = mtime
        if self.grade_config.get("enabled"):
            rows, mtime = gradescope.read_cache(GRADESCOPE_CACHE)
            self.feed_items[GRADESCOPE_SOURCE] = gradescope_items(rows)
            self.status.setdefault(
                GRADESCOPE_SOURCE, FeedStatus(name="Gradescope")).cached_at = mtime

    def refresh(self) -> None:
        for st in self.status.values():
            st.pending = True
        self.queue = start_fetches(
            self.feeds, self.settings["fetch_timeout"], self.grade_config,
            self.settings["horizon_days"])

    def has_sources(self) -> bool:
        return bool(self.feeds or self.grade_config.get("enabled"))

    def drain(self) -> bool:
        """Absorb finished fetches.  Returns True if anything changed."""
        if self.queue is None:
            return False
        changed = False
        while True:
            try:
                feed, text, err = self.queue.get_nowait()
            except queue.Empty:
                break
            source_id = feed if feed == GRADESCOPE_SOURCE else feed.url
            st = self.status[source_id]
            st.pending = False
            if err is None:
                try:
                    if feed == GRADESCOPE_SOURCE:
                        self.feed_items[source_id] = gradescope_items(text)
                    else:
                        self.feed_items[source_id] = items_from_ics(
                            text, feed, self.settings["horizon_days"])
                    st.ok, st.error, st.cached_at = True, None, time.time()
                except Exception as exc:
                    st.ok, st.error = False, f"parse: {type(exc).__name__}"
            else:
                st.ok, st.error = False, err
            changed = True
        if all(not s.pending for s in self.status.values()):
            self.queue = None
        return changed

    def live_items(self) -> dict[str, Item]:
        """Everything currently sourced from a feed or the manual list."""
        live: dict[str, Item] = {}
        for items in self.feed_items.values():
            for it in items:
                live.setdefault(it.key, it)
        for it in self.manual:
            live[it.key] = it
        return live

    def rebuild(self, keep_key: str | None = None, keep_screen_row: int = 0) -> None:
        live = self.live_items()
        main = [it for key, it in live.items() if key not in self.completed]
        for it in main:
            it.checked = it.key in self.checked

        done: list[Item] = []
        for key, snap in self.completed.items():
            it = Item.from_json(snap)
            if it is None:
                continue
            it.checked = key in self.checked
            done.append(it)

        self.rows, self.main_start = build_rows(done, main)

        # Re-anchor the cursor on the item it was on, not on a row number.
        if keep_key is not None:
            found = next((i for i, r in enumerate(self.rows)
                          if r.kind == "item" and r.item and r.item.key == keep_key), None)
            if found is not None:
                self.cursor = found
                self.scroll = max(0, found - keep_screen_row)
            else:
                self.cursor = min(self.cursor, len(self.rows) - 1)
                self.snap_to_item(+1) or self.snap_to_item(-1)
        else:
            self.cursor = self.main_start
            self.scroll = self.main_start
            if not self.snap_to_item(+1):
                self.snap_to_item(-1)
        self.dirty = True

    # -- cursor ----------------------------------------------------------

    def item_rows(self) -> list[int]:
        return [i for i, r in enumerate(self.rows) if r.kind == "item"]

    def current(self) -> Item | None:
        if 0 <= self.cursor < len(self.rows):
            row = self.rows[self.cursor]
            if row.kind == "item":
                return row.item
        return None

    def snap_to_item(self, direction: int) -> bool:
        """Move the cursor onto the nearest item row in `direction`."""
        i = max(0, min(self.cursor, len(self.rows) - 1))
        while 0 <= i < len(self.rows):
            if self.rows[i].kind == "item":
                self.cursor = i
                return True
            i += direction
        return False

    def move(self, delta: int) -> None:
        items = self.item_rows()
        if not items:
            return
        after = [i for i in items if i > self.cursor]
        before = [i for i in items if i < self.cursor]
        if delta > 0 and after:
            self.cursor = after[0]
        elif delta < 0 and before:
            self.cursor = before[-1]
        self.dirty = True

    # -- drawing ---------------------------------------------------------

    def clamp(self, body: int) -> None:
        """Keep the viewport legal.

        The lower bound of `max_scroll` is `main_start`, not `len(rows)-body`:
        otherwise a short main list would drag the Completed section down into
        view, which is exactly what it must not do.
        """
        max_scroll = max(self.main_start, len(self.rows) - body)
        self.scroll = max(0, min(self.scroll, max_scroll))

    def ensure_visible(self, body: int) -> None:
        if self.cursor < self.scroll:
            self.scroll = self.cursor
            # Pull the day header (and its blank line) along for context.
            back = 0
            while (back < 2 and self.scroll > 0
                   and self.rows[self.scroll - 1].kind in ("header", "blank")):
                self.scroll -= 1
                back += 1
            # Nothing selectable remains above: show the very top, so the
            # "Completed" banner is actually reachable.
            if not any(r.kind == "item" for r in self.rows[:self.scroll]):
                self.scroll = 0
        elif self.cursor >= self.scroll + body:
            self.scroll = self.cursor - body + 1

    def attr(self, name: str) -> int:
        return self.pairs.get(name, curses.A_NORMAL)

    def setup_colors(self) -> None:
        self.pairs = {}
        if not curses.has_colors():
            self.pairs = {"dim": curses.A_DIM, "header": curses.A_BOLD,
                          "overdue": curses.A_BOLD, "accent": curses.A_NORMAL,
                          "done": curses.A_DIM}
            return
        curses.start_color()
        try:
            curses.use_default_colors()
        except curses.error:
            pass
        curses.init_pair(1, curses.COLOR_BLUE, -1)
        curses.init_pair(2, curses.COLOR_RED, -1)
        curses.init_pair(3, curses.COLOR_CYAN, -1)
        curses.init_pair(4, curses.COLOR_GREEN, -1)
        self.pairs = {
            "dim": curses.A_DIM,
            "header": curses.color_pair(1) | curses.A_BOLD,
            "overdue": curses.color_pair(2) | curses.A_BOLD,
            "accent": curses.color_pair(3),
            "done": curses.color_pair(4) | curses.A_DIM,
        }

    def put(self, y: int, x: int, text: str, attr: int, w: int) -> None:
        """Write clipped to w-1 columns.  Overflow silently wraps in curses."""
        room = w - 1 - x
        if room <= 0 or not text:
            return
        try:
            self.stdscr.addstr(y, x, dtrim(text, room), attr)
        except curses.error:
            pass

    def item_line(self, it: Item, w: int) -> tuple[str, str, str]:
        box = "[x]" if it.checked else "[ ]"
        clock = it.time_label()
        prefix = f"{box} {clock:>5}  "
        source = it.source if w >= 56 else ""
        tail = f"  {source}" if source else ""
        room = (w - 1) - dwidth(prefix) - dwidth(tail)
        title = it.title + ("  ↗" if it.link else "")
        return prefix, dtrim(title, max(4, room)), tail

    def draw_row(self, y: int, row: Row, w: int, selected: bool) -> None:
        if row.kind == "blank":
            return
        if row.kind == "rule":
            self.put(y, 1, "─" * max(0, w - 3), self.attr("dim"), w)
            return
        if row.kind == "header":
            if row.style == "section":
                label = f"── {row.text} "
                self.put(y, 1, label + "─" * max(0, w - 4 - dwidth(label)),
                         self.attr("done"), w)
            else:
                style = "overdue" if row.style == "overdue" else "header"
                self.put(y, 1, row.text, self.attr(style), w)
            return

        it = row.item
        assert it is not None
        prefix, title, tail = self.item_line(it, w)
        base = self.attr("done") if it.checked else curses.A_NORMAL
        self.put(y, 1, prefix, base | (curses.A_DIM if it.checked else 0), w)
        self.put(y, 1 + dwidth(prefix), title, base, w)
        if tail:
            self.put(y, w - 1 - dwidth(tail) + 1, tail.strip(), self.attr("dim"), w)
        if selected:
            # chgat extends the highlight to the edge without writing cells,
            # which would wrap the line.
            try:
                self.stdscr.chgat(y, 0, -1, curses.A_REVERSE)
            except curses.error:
                pass

    def status_line(self) -> tuple[str, str]:
        if self.message and time.time() < self.message_until:
            return self.message, self.gradescope_status()
        today = date.today()
        main_open = [r.item for r in self.rows[self.main_start:]
                     if r.kind == "item" and r.item and not r.item.checked]
        overdue = sum(1 for it in main_open if it.day is not None and it.day < today)
        bits = [f"{len(main_open)} open"]
        if overdue:
            bits.append(f"{overdue} overdue")
        feed_status = [self.status[f.url] for f in self.feeds]
        if feed_status:
            failed = [s for s in feed_status if not s.pending and s.error]
            pending = any(s.pending for s in feed_status)
            newest = max((s.cached_at or 0 for s in feed_status), default=0)
            if pending:
                bits.append("fetching…")
            elif failed:
                bits.append(f"{failed[0].name}: {failed[0].error}")
            else:
                bits.append(f"updated {rel_time(newest or None)}")
        elif not self.grade_config.get("enabled"):
            bits.append(f"no feeds — see {CONFIG_PATH}")
        return " · ".join(bits), self.gradescope_status()

    def gradescope_status(self) -> str:
        if not self.grade_config.get("enabled"):
            return ""
        st = self.status.get(GRADESCOPE_SOURCE)
        if st is None:
            return "Gradescope: never synced"
        if st.pending:
            return "Gradescope: syncing…"
        if st.error:
            return f"Gradescope: {st.error}"
        return f"Gradescope synced {rel_time(st.cached_at)}"

    def draw(self) -> None:
        h, w = self.stdscr.getmaxyx()
        self.stdscr.erase()
        if h < 3 or w < 24:
            self.put(0, 0, "terminal too small", curses.A_NORMAL, w)
            self.stdscr.refresh()
            return
        body = h - 1
        self.ensure_visible(body)
        self.clamp(body)
        for i in range(body):
            idx = self.scroll + i
            if idx >= len(self.rows):
                break
            self.draw_row(i, self.rows[idx], w, selected=(idx == self.cursor))
        left, right = self.status_line()
        right = dtrim(right, max(0, w // 2))
        right_width = dwidth(right)
        left_room = max(0, w - 3 - right_width)
        left = dtrim(left, left_room)
        try:
            self.stdscr.addstr(h - 1, 0, " " * (w - 1), self.attr("dim"))
            self.stdscr.addstr(h - 1, 1, left, self.attr("dim"))
            if right:
                self.stdscr.addstr(h - 1, w - 1 - right_width, right, self.attr("dim"))
        except curses.error:
            pass
        self.stdscr.refresh()

    def notify(self, text: str, seconds: float = 3.0) -> None:
        self.message = text
        self.message_until = time.time() + seconds
        self.dirty = True

    # -- input -----------------------------------------------------------

    def read_key(self):
        """Return a str for text, an int for special keys, or None on timeout.

        Prefers get_wch (widechar ncurses); falls back to assembling UTF-8 from
        raw getch bytes on builds that lack it.
        """
        try:
            ch = self.stdscr.get_wch()
        except curses.error:
            return None                       # timeout tick
        except AttributeError:
            ch = self.stdscr.getch()
            if ch == -1:
                return None
            if 0x80 <= ch <= 0xFF:
                if ch >= 0xF0:
                    need = 3
                elif ch >= 0xE0:
                    need = 2
                elif ch >= 0xC0:
                    need = 1
                else:
                    need = 0
                buf = bytearray([ch])
                for _ in range(need):
                    nxt = self.stdscr.getch()
                    if nxt == -1:
                        break
                    buf.append(nxt)
                return buf.decode("utf-8", errors="replace")
            if 32 <= ch < 127:
                return chr(ch)
            return ch
        return ch

    def swallow_escape_sequence(self) -> None:
        """Eat a CSI sequence (e.g. a bracketed-paste marker) after a bare ESC."""
        self.stdscr.timeout(20)
        try:
            nxt = self.stdscr.getch()
            if nxt not in (ord("["), ord("O")):
                return
            for _ in range(32):
                b = self.stdscr.getch()
                if b == -1 or 0x40 <= b <= 0x7E:
                    return
        finally:
            self.stdscr.timeout(-1)

    def prompt(self, label: str, initial: str = "") -> str | None:
        """Read one line on the bottom row.  ESC cancels and returns None."""
        buf = list(initial)
        h, w = self.stdscr.getmaxyx()
        self.stdscr.timeout(-1)
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        try:
            while True:
                h, w = self.stdscr.getmaxyx()
                text = "".join(buf)
                shown = label + text
                # Horizontally scroll the field once it outgrows the line.
                while dwidth(shown) > w - 2 and shown:
                    text_start = len(shown) - (w - 2)
                    shown = "…" + shown[max(0, text_start) + 1:]
                try:
                    self.stdscr.move(h - 1, 0)
                    self.stdscr.clrtoeol()
                    self.stdscr.addnstr(h - 1, 0, shown, w - 1, curses.A_BOLD)
                    self.stdscr.move(h - 1, min(dwidth(shown), w - 1))
                except curses.error:
                    pass
                self.stdscr.refresh()

                key = self.read_key()
                if key is None:
                    continue
                if key == curses.KEY_RESIZE or key == "\x0c":
                    self.stdscr.clear()
                    self.draw()
                    continue
                if key == "\x1b":
                    self.swallow_escape_sequence()
                    return None
                if key in ("\n", "\r") or key in (curses.KEY_ENTER, 10, 13):
                    return "".join(buf)
                if key in ("\x7f", "\b", "\x08") or key in (curses.KEY_BACKSPACE, 263, 127, 8):
                    if buf:
                        buf.pop()
                    continue
                if key == "\x15":                      # ctrl-u
                    buf.clear()
                    continue
                if isinstance(key, str) and key.isprintable():
                    buf.append(key)
        finally:
            try:
                curses.curs_set(0)
            except curses.error:
                pass

    def show_help(self) -> None:
        h, w = self.stdscr.getmaxyx()
        self.stdscr.erase()
        self.put(0, 1, "gsd — keys", self.attr("header"), w)
        for i, (keys, what) in enumerate(HELP_LINES):
            if 2 + i >= h - 1:
                break
            self.put(2 + i, 2, f"{keys:<16}", self.attr("accent"), w)
            self.put(2 + i, 20, what, curses.A_NORMAL, w)
        row = min(h - 2, 3 + len(HELP_LINES))
        self.put(row, 2, f"config  {CONFIG_PATH}", self.attr("dim"), w)
        self.put(row + 1, 2, f"state   {STATE_PATH}", self.attr("dim"), w)
        self.put(row + 2, 2, f"timezone {self.settings.get('resolved_timezone') or LOCAL}",
                 self.attr("dim"), w)
        self.put(h - 1, 1, "any key to return", self.attr("dim"), w)
        self.stdscr.refresh()
        self.stdscr.timeout(-1)
        self.read_key()
        self.dirty = True

    def show_sources(self) -> None:
        """Small config UI for toggling calendar feeds and bundled plugins."""
        entries = [("gradescope", GRADESCOPE_SOURCE, "Gradescope plugin",
                    bool(self.grade_config.get("enabled")))]
        entries.extend(("feed", feed.url, f"Calendar · {feed.name}", feed.enabled)
                       for feed in self.all_feeds)
        selected = 0
        changed = False
        self.stdscr.timeout(-1)
        while True:
            h, w = self.stdscr.getmaxyx()
            self.stdscr.erase()
            self.put(0, 1, "Sources", self.attr("header"), w)
            self.put(1, 1, "space toggle · t timezone · e edit config · q/esc done",
                     self.attr("dim"), w)
            zone = self.settings.get("resolved_timezone") or str(LOCAL)
            self.put(2, 1, f"Timezone: {zone}", self.attr("dim"), w)
            for idx, (_kind, _identifier, label, enabled) in enumerate(entries[:max(0, h - 5)]):
                line = f"[{'x' if enabled else ' '}] {label}"
                self.put(idx + 4, 2, line, curses.A_NORMAL, w)
                if idx == selected:
                    try:
                        self.stdscr.chgat(idx + 4, 0, -1, curses.A_REVERSE)
                    except curses.error:
                        pass
            self.put(h - 1, 1, str(CONFIG_PATH), self.attr("dim"), w)
            self.stdscr.refresh()
            key = self.read_key()
            if key in ("q", "Q", "\x1b", "\n", "\r"):
                break
            if key in ("j", "J") or key == curses.KEY_DOWN:
                selected = min(len(entries) - 1, selected + 1)
            elif key in ("k", "K") or key == curses.KEY_UP:
                selected = max(0, selected - 1)
            elif key == " " and entries:
                kind, identifier, label, enabled = entries[selected]
                try:
                    set_source_enabled(kind, identifier, not enabled)
                except Exception as exc:
                    self.notify(f"config: {type(exc).__name__}")
                    break
                entries[selected] = (kind, identifier, label, not enabled)
                if kind == "gradescope":
                    self.grade_config["enabled"] = not enabled
                else:
                    next(f for f in self.all_feeds if f.url == identifier).enabled = not enabled
                changed = True
            elif key in ("e", "E"):
                # Leave curses before invoking the user's editor.
                curses.endwin()
                edit_config()
                try:
                    curses.reset_prog_mode()
                except curses.error:
                    pass
                self.stdscr.clear()
                self.stdscr.refresh()
                self.notify("config edited; restart gsd to reload it", seconds=5)
                return
            elif key in ("t", "T"):
                raw = self.prompt("Timezone (IANA name or auto): ",
                                  str(self.settings.get("timezone") or "auto"))
                if raw is None:
                    continue
                try:
                    resolved = configure_timezone(raw)
                except ValueError as exc:
                    self.notify(str(exc), seconds=5)
                    return
                self.settings["timezone"] = "auto" if raw.strip().lower() in ("", "auto") else raw.strip()
                self.settings["resolved_timezone"] = resolved
                changed = True
        if changed:
            self.apply_source_changes()
            self.notify("source settings saved")
        self.dirty = True

    def apply_source_changes(self) -> None:
        """Apply source-manager toggles immediately without restarting."""
        # Results from the previous source set are no longer authoritative.
        # Its daemon workers may finish, but their now-unreferenced queue is safe.
        self.queue = None
        self.feeds = [feed for feed in self.all_feeds if feed.enabled]
        active = {feed.url for feed in self.feeds}
        if self.grade_config.get("enabled"):
            active.add(GRADESCOPE_SOURCE)
        self.feed_items = {key: value for key, value in self.feed_items.items() if key in active}
        old = self.status
        self.status = {feed.url: old.get(feed.url, FeedStatus(name=feed.name))
                       for feed in self.feeds}
        if self.grade_config.get("enabled"):
            self.status[GRADESCOPE_SOURCE] = old.get(
                GRADESCOPE_SOURCE, FeedStatus(name="Gradescope"))
        self.load_caches()
        self.rebuild()
        if self.can_fetch and self.has_sources():
            self.refresh()

    def open_link(self, it: Item) -> None:
        if not it.link:
            self.notify("no link on this event")
            return
        try:
            browser = webbrowser.get()
        except webbrowser.Error:
            self.notify("no browser available")
            return
        if isinstance(browser, webbrowser.GenericBrowser):
            # A terminal browser would take over the screen and block on wait().
            self.notify(f"link: {it.link}", seconds=8)
            return
        threading.Thread(target=lambda: browser.open(it.link), daemon=True).start()
        self.notify("opening link…", seconds=1.5)
        self.stdscr.redrawwin()

    # -- actions ---------------------------------------------------------

    def screen_row(self) -> int:
        return max(0, self.cursor - self.scroll)

    def toggle(self) -> None:
        it = self.current()
        if it is None:
            return
        it.checked = not it.checked
        if it.checked:
            self.checked.add(it.key)
        else:
            self.checked.discard(it.key)
        # Only the glyph changes; nothing reflows until quit.
        self.state["checked"] = sorted(self.checked)
        save_state(self.state)
        self.dirty = True

    def add_item(self) -> None:
        title = self.prompt("Title: ")
        if title is None or not title.strip():
            return
        while True:
            raw = self.prompt("Due (today / fri / 9-12 / 2026-09-12, +time): ")
            if raw is None:
                return
            when = parse_when(raw)
            if when is not None:
                break
            self.notify("could not read that date — try 'fri' or 2026-09-12")
            self.draw()
        due, all_day = when
        item = Item(key=uuid.uuid4().hex, title=clean_text(title), due=due,
                    all_day=all_day, source="manual", manual=True)
        self.manual.append(item)
        self.persist_manual()
        self.rebuild(keep_key=item.key, keep_screen_row=self.screen_row())
        self.notify(f"added for {due:%a %b %-d}")

    def edit_item(self) -> None:
        it = self.current()
        if it is None:
            return
        if not it.manual:
            self.notify("only manual items can be edited")
            return
        title = self.prompt("Title: ", it.title)
        if title is None or not title.strip():
            return
        target = next((m for m in self.manual if m.key == it.key), None)
        if target is None:
            return
        target.title = clean_text(title)
        self.persist_manual()
        self.rebuild(keep_key=it.key, keep_screen_row=self.screen_row())

    def delete_item(self) -> None:
        it = self.current()
        if it is None:
            return
        if not it.manual:
            self.notify("only manual items can be deleted")
            return
        answer = self.prompt(f"Delete “{dtrim(it.title, 40)}”? [y/N] ")
        if not answer or answer.strip().lower() not in ("y", "yes"):
            return
        self.manual = [m for m in self.manual if m.key != it.key]
        self.checked.discard(it.key)
        self.completed.pop(it.key, None)
        self.persist_manual()
        self.rebuild()
        self.notify("deleted")

    def persist_manual(self) -> None:
        self.state["manual"] = [m.to_json() for m in self.manual]
        self.state["checked"] = sorted(self.checked)
        save_state(self.state)

    def reconcile_and_save(self) -> None:
        """Quit-time sweep: checked items become Completed, unchecked return."""
        live = self.live_items()
        now = datetime.now(LOCAL).isoformat(timespec="seconds")
        new_completed: dict[str, dict] = {}

        for key in self.checked:
            previous = self.completed.get(key)
            if previous is not None:
                snap = dict(previous)
                snap.setdefault("completed_at", now)
            elif key in live:
                item = live[key]
                snap = item.to_json()
                snap["completed_at"] = now
            else:
                continue
            new_completed[key] = snap

        # An item unchecked inside Completed whose feed entry is gone would
        # otherwise vanish; keep it by turning it into a manual item.
        manual_keys = {m.key for m in self.manual}
        for key, snap in self.completed.items():
            if key in self.checked or key in live or key in manual_keys:
                continue
            restored = Item.from_json(snap)
            if restored is None:
                continue
            restored.manual = True
            restored.source = snap.get("source") or "manual"
            restored.completed_at = None
            self.manual.append(restored)

        self.completed = prune_completed(new_completed, self.settings["retention_days"])
        cap = 500
        if len(self.completed) > cap:
            ordered = sorted(self.completed.items(),
                             key=lambda kv: kv[1].get("completed_at") or "", reverse=True)
            self.completed = dict(ordered[:cap])

        self.state["completed"] = self.completed
        self.state["manual"] = [m.to_json() for m in self.manual]
        self.state["checked"] = sorted(self.completed)
        save_state(self.state)

    # -- loop ------------------------------------------------------------

    def run(self, fetch: bool = True) -> None:
        curses.curs_set(0)
        try:
            curses.set_escdelay(25)
        except (AttributeError, curses.error):
            pass
        self.setup_colors()
        self.load_caches()
        self.rebuild()
        self.can_fetch = fetch
        if self.has_sources() and fetch:
            self.refresh()
        elif not fetch:
            for status in self.status.values():
                status.pending = False

        while True:
            self.stdscr.timeout(150 if self.queue is not None else 1000)
            if self.dirty:
                self.draw()
                self.dirty = False
            key = self.read_key()

            if self.drain():
                it = self.current()
                self.rebuild(keep_key=it.key if it else None,
                             keep_screen_row=self.screen_row())
            if self.message and time.time() >= self.message_until:
                self.message = ""
                self.dirty = True

            if key is None:
                continue
            if key == curses.KEY_RESIZE:
                curses.update_lines_cols()
                self.stdscr.clear()          # erase() leaves stale cells on shrink
                self.dirty = True
                continue
            if key in ("q", "Q"):
                self.reconcile_and_save()
                return
            if key in ("j", "J") or key == curses.KEY_DOWN:
                self.move(+1)
            elif key in ("k", "K") or key == curses.KEY_UP:
                self.move(-1)
            elif key == "g" or key == curses.KEY_HOME:
                items = self.item_rows()
                if items:
                    self.cursor = items[0]
                    self.dirty = True
            elif key == "G" or key == curses.KEY_END:
                items = self.item_rows()
                if items:
                    self.cursor = items[-1]
                    self.dirty = True
            elif key in (curses.KEY_NPAGE, curses.KEY_PPAGE):
                # Step a screenful of *items*; ensure_visible owns the scroll.
                step = max(1, self.stdscr.getmaxyx()[0] // 2)
                for _ in range(step):
                    self.move(+1 if key == curses.KEY_NPAGE else -1)
            elif key == " ":
                self.toggle()
            elif key in ("\n", "\r") or key in (curses.KEY_ENTER, 10, 13):
                it = self.current()
                if it is not None:
                    self.open_link(it)
            elif key == "a":
                self.add_item()
            elif key == "e":
                self.edit_item()
            elif key == "d":
                self.delete_item()
            elif key == "r":
                if self.has_sources() and self.can_fetch:
                    self.refresh()
                    self.notify("refreshing…", seconds=1.5)
                else:
                    self.notify(f"no sources configured — {CONFIG_PATH}")
            elif key == "c":
                self.show_sources()
            elif key == "?":
                self.show_help()


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------

def collect_items(feeds: list[Feed], settings: dict, state: dict,
                  fetch: bool) -> tuple[list[Item], list[Item]]:
    """Non-interactive gathering, used by --list."""
    items: dict[str, Item] = {}
    for feed in (source for source in feeds if source.enabled):
        text = None
        if fetch:
            try:
                text = fetch_text(feed.url, settings["fetch_timeout"])
                feed.cache_path.write_text(text)
            except Exception:
                text = None
        if text is None:
            text, _ = read_cache(feed)
        if not text:
            continue
        try:
            for it in items_from_ics(text, feed, settings["horizon_days"]):
                items.setdefault(it.key, it)
        except Exception:
            continue
    grade_config = settings.get("gradescope") or {}
    if grade_config.get("enabled"):
        rows = None
        if fetch:
            try:
                rows = gradescope.fetch(grade_config, GRADESCOPE_COOKIES,
                                         settings["fetch_timeout"],
                                         settings["horizon_days"])
                gradescope.write_cache(GRADESCOPE_CACHE, rows)
            except Exception:
                rows = None
        if rows is None:
            rows, _ = gradescope.read_cache(GRADESCOPE_CACHE)
        for item in gradescope_items(rows):
            items.setdefault(item.key, item)
    for d in state.get("manual", []):
        it = Item.from_json(d)
        if it:
            it.manual = True
            items[it.key] = it
    completed = state.get("completed", {})
    main = [it for k, it in items.items() if k not in completed]
    done = [it for it in (Item.from_json(s) for s in completed.values()) if it]
    return sorted(main, key=lambda i: i.sort_key), sorted(done, key=lambda i: i.sort_key)


def plain_dump(feeds: list[Feed], settings: dict, state: dict, fetch: bool) -> None:
    main, done = collect_items(feeds, settings, state, fetch)
    rows, main_start = build_rows(done, main)
    for row in rows[main_start:]:
        if row.kind == "blank":
            print()
        elif row.kind == "header":
            print(row.text)
        elif row.kind == "rule":
            continue
        elif row.item is not None:
            it = row.item
            clock = it.time_label()
            print(f"[ ] {clock:>5}  {it.title}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog=APP, description="A minimal assignment TUI with pluggable sources.")
    ap.add_argument("--add-feed", metavar="URL",
                    help="append a calendar feed to the config and exit")
    ap.add_argument("--name", metavar="NAME", help="label for --add-feed")
    ap.add_argument("--list", action="store_true",
                    help="print the list as plain text and exit")
    ap.add_argument("--no-fetch", action="store_true",
                    help="use cached feeds only, never touch the network")
    ap.add_argument("--edit-config", action="store_true",
                    help="open config.toml in $VISUAL or $EDITOR")
    ap.add_argument("--timezone", metavar="ZONE",
                    help="set an IANA timezone, or 'auto', and exit")
    ap.add_argument("--gradescope-login", metavar="EMAIL",
                    help="log into Gradescope and enable its plugin")
    ap.add_argument("--gradescope-import-cookies", metavar="FILE",
                    help="import a browser cookies.txt for Gradescope")
    ap.add_argument("--gradescope-logout", action="store_true",
                    help="remove the Gradescope session and stored password")
    args = ap.parse_args(argv)

    if args.timezone is not None:
        try:
            resolved = configure_timezone(args.timezone)
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 2
        print(f"timezone: {resolved} ({'auto' if args.timezone.lower() == 'auto' else 'configured'})")
        return 0

    # Parse config before curses starts, so an error prints legibly.
    try:
        feeds, settings = load_config()
    except ValueError as exc:
        print(f"config: {exc}", file=sys.stderr)
        return 2

    if args.edit_config:
        return edit_config()

    if args.add_feed:
        name = add_feed_to_config(args.add_feed, args.name)
        print(f"added feed “{name}” to {CONFIG_PATH}")
        return 0

    if args.gradescope_login:
        try:
            gradescope.login(args.gradescope_login.strip(), GRADESCOPE_COOKIES)
            configure_gradescope(args.gradescope_login.strip(), enabled=True)
        except gradescope.GradescopeError as exc:
            print(f"Gradescope login failed: {exc}", file=sys.stderr)
            return 1
        print(f"Gradescope plugin enabled for {args.gradescope_login.strip()}")
        return 0

    if args.gradescope_import_cookies:
        email = (settings.get("gradescope") or {}).get("email", "")
        try:
            gradescope.import_cookies(Path(args.gradescope_import_cookies).expanduser(),
                                      GRADESCOPE_COOKIES)
        except gradescope.GradescopeError as exc:
            print(f"Cookie import failed: {exc}", file=sys.stderr)
            return 1
        configure_gradescope(email, enabled=True)
        print("Gradescope cookies imported; plugin enabled")
        return 0

    if args.gradescope_logout:
        email = (settings.get("gradescope") or {}).get("email", "")
        deleted = gradescope.delete_password(email) if email else False
        try:
            GRADESCOPE_COOKIES.unlink()
        except FileNotFoundError:
            pass
        configure_gradescope(email, enabled=False)
        print(f"Gradescope credentials removed ({'Keychain and session' if deleted else 'session'})")
        return 0

    state = load_state()

    if args.list or not sys.stdout.isatty():
        plain_dump(feeds, settings, state, fetch=not args.no_fetch)
        return 0

    def bootstrap(stdscr):
        App(stdscr, feeds, settings, state).run(fetch=not args.no_fetch)

    try:
        curses.wrapper(bootstrap)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
