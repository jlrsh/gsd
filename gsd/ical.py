"""RFC 5545 parsing, recurrence expansion, and calendar-to-item conversion."""

from __future__ import annotations

import hashlib
import html
import re
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from . import timezones
from .models import Feed, Item

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
        return timezones.LOCAL
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

    tz = timezones.LOCAL
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
    head, value = line[:idx], line[idx + 1 :]
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
        return d.replace(tzinfo=timezones.LOCAL), True
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
            if (
                current is not None
                and len(stack) == depth_of_current
                and kind == current["_kind"]
            ):
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


def expand_rrule(
    dtstart: datetime, rule: dict[str, str], lo: datetime, hi: datetime, cap: int = 500
) -> list[datetime]:
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

    raw_byday = [
        t.strip().upper() for t in rule.get("BYDAY", "").split(",") if t.strip()
    ]
    byday = [WEEKDAYS[t[-2:]] for t in raw_byday if t[-2:] in WEEKDAYS]
    nth_byday: list[tuple[int, int]] = []
    for tok in raw_byday:
        m = re.fullmatch(r"([+-]?\d+)(MO|TU|WE|TH|FR|SA|SU)", tok)
        if m:
            nth_byday.append((int(m.group(1)), WEEKDAYS[m.group(2)]))
    try:
        bymonthday = [
            int(x) for x in rule.get("BYMONTHDAY", "").split(",") if x.strip()
        ]
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
                    days.append(
                        date(anchor.year, anchor.month, md)
                        if md > 0
                        else _month_end(anchor.year, anchor.month, md)
                    )
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
    now = datetime.now(timezones.LOCAL)
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
            overrides[(_uid_of(comp, ""), dt.astimezone(timezones.LOCAL).date())] = comp
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
                    items.append(
                        Item(
                            key=key,
                            title=title,
                            due=None,
                            all_day=True,
                            link=extract_link(comp),
                            source=feed.name,
                        )
                    )
            continue
        dtstart, all_day = got

        rrule_prop = first(comp, "RRULE")
        if rrule_prop:
            occurrences = expand_rrule(
                dtstart, parse_rrule(rrule_prop[1]), recur_lo, hi
            )
        else:
            occurrences = [dtstart] if single_lo <= dtstart <= hi else []
        for extra in _date_set(comp, "RDATE"):
            if single_lo <= extra <= hi:
                occurrences.append(extra)

        skip = {d.astimezone(timezones.LOCAL).date() for d in _date_set(comp, "EXDATE")}

        for occ in occurrences:
            occ_day = occ.astimezone(timezones.LOCAL).date()
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
                    shown_comp = comp  # inherit the series' link
            seen.add(key)
            items.append(
                Item(
                    key=key,
                    title=shown_title,
                    due=shown_dt,
                    all_day=shown_all_day,
                    link=extract_link(shown_comp),
                    source=feed.name,
                )
            )
    return items
