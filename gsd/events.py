"""Event grouping, display rows, and manual due-date parsing."""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta

from . import timezones
from .models import Item, Row


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


_WEEKDAY_NAMES = [
    ("mon", "monday"),
    ("tue", "tues", "tuesday"),
    ("wed", "weds", "wednesday"),
    ("thu", "thur", "thurs", "thursday"),
    ("fri", "friday"),
    ("sat", "saturday"),
    ("sun", "sunday"),
]
_DATE_FORMATS = [
    ("%Y-%m-%d", True),
    ("%Y/%m/%d", True),
    ("%m/%d/%Y", True),
    ("%m/%d/%y", True),
    ("%m/%d", False),
    ("%m-%d", False),
    ("%b %d", False),
    ("%d %b", False),
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
        return None  # a bare number is a day, not a time
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
        return datetime.combine(today, datetime.min.time(), timezones.LOCAL), True

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
                        f"{body} {today.year + bump}", f"{fmt} %Y"
                    ).date()
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
        return datetime.combine(day, datetime.min.time(), timezones.LOCAL), True
    return datetime.combine(
        day,
        datetime.min.time().replace(hour=clock[0], minute=clock[1]),
        timezones.LOCAL,
    ), False
