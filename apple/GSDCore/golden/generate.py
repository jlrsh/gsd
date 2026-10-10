"""Emit golden JSON from the Python gsd package for the Swift parity tests.

Run from the repo root:  uv run python apple/GSDCore/golden/generate.py

`now` and the local zone are frozen per case so the Swift functions, which take
both as parameters, can be asserted against exactly what Python produced.
Fixtures under Fixtures/private (real feeds/pages) are included when present
and their goldens are written next to them, so nothing personal is committed.
"""

from __future__ import annotations

import datetime as _dt
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from bs4 import BeautifulSoup  # noqa: E402

from gsd import events, ical, models, sources, timezones  # noqa: E402
from gsd.models import Feed  # noqa: E402
from gsd.plugins import gradescope  # noqa: E402

FIX = Path(__file__).resolve().parents[1] / "Tests" / "GSDCoreTests" / "Fixtures"
OUT = FIX / "golden"
PRIVATE = FIX / "private"

_FROZEN: _dt.datetime | None = None


class FrozenDatetime(_dt.datetime):
    @classmethod
    def now(cls, tz=None):
        assert _FROZEN is not None
        value = _FROZEN.astimezone(tz) if tz else _FROZEN.astimezone(timezones.LOCAL).replace(tzinfo=None)
        return cls.combine(value.date(), value.timetz())


class FrozenDate(_dt.date):
    @classmethod
    def today(cls):
        assert _FROZEN is not None
        d = _FROZEN.astimezone(timezones.LOCAL).date()
        return cls(d.year, d.month, d.day)


for module in (ical, events, models, sources):
    if hasattr(module, "datetime"):
        module.datetime = FrozenDatetime
events.date = FrozenDate


def freeze(now_iso: str, zone: str) -> None:
    global _FROZEN
    timezones.select_local_timezone(zone)
    ical._TZ_CACHE.clear()
    _FROZEN = _dt.datetime.fromisoformat(now_iso)


def utc(d: _dt.datetime | None) -> str | None:
    if d is None:
        return None
    return d.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def item_json(it: models.Item) -> dict:
    return {
        "key": it.key,
        "title": it.title,
        "due": utc(it.due),
        "allDay": it.all_day,
        "link": it.link,
        "source": it.source,
    }


def rows_json(rows: list[models.Row]) -> list[list]:
    return [[r.kind, r.text, r.style, r.item.key if r.item else None] for r in rows]


CLOCKS = [
    ("2026-09-24T10:00:00-04:00", "America/Indiana/Indianapolis", 120),
    ("2026-10-31T23:30:00-07:00", "America/Los_Angeles", 60),
    ("2026-11-02T00:30:00+09:00", "Asia/Tokyo", 120),
    ("2026-09-10T03:59:30+00:00", "UTC", 30),
]


def ics_cases(paths: list[Path]) -> list[dict]:
    cases = []
    for path in paths:
        raw = path.read_bytes()
        if raw[:2] == b"\x1f\x8b":
            import gzip

            raw = gzip.decompress(raw)
        text = ical.decode_ics(raw)
        for now_iso, zone, horizon in CLOCKS:
            freeze(now_iso, zone)
            feed = Feed(url=f"https://example.test/{path.name}", name=path.stem)
            items = ical.items_from_ics(text, feed, horizon)
            main = sorted(items, key=lambda i: i.sort_key)
            rows, start = events.build_rows([], main)
            # Completed rendering: pretend the first three are done.
            done_rows, done_start = events.build_rows(main[:3], main[3:])
            cases.append(
                {
                    "file": path.name,
                    "now": now_iso,
                    "zone": zone,
                    "horizon": horizon,
                    "looksLikeCalendar": ical.looks_like_calendar(text),
                    "items": [item_json(i) for i in items],
                    "rows": rows_json(rows),
                    "mainStart": start,
                    "doneRows": rows_json(done_rows),
                    "doneStart": done_start,
                    "overdue": [i.key for i in items if i.is_overdue()],
                    "timeLabels": [i.time_label() for i in items],
                }
            )
    return cases


WHEN_INPUTS = [
    "", "today", "tod", "tomorrow", "tmr", "tom", "+0", "+3", "+45",
    "mon", "Tuesday", "wed", "weds", "thu", "thurs", "fri", "sat", "sun",
    "fri 5pm", "fri 17:00", "today 11:59pm", "tomorrow 12am", "tomorrow 12pm",
    "9/12", "9/12 23:59", "09/05", "12/31", "1/1", "2/29", "2/30", "13/1",
    "2026-09-12", "2026/9/5", "9/12/2027", "9/12/27", "3/4/70", "10-31",
    "Sep 12", "sep 12 9am", "12 Sep", "september 12", "Sept 12", "oct 5 17:30",
    "  fri    5pm  ", "5pm", "17:00", "fri 25:00", "fri 13pm", "fri 0am",
    "fri 7", "hello", "9/12 5 pm", "+3 8:05", "2026-02-29", "2028-02-29 1:00am",
]


def when_cases() -> list[dict]:
    out = []
    for now_iso, zone, _ in CLOCKS:
        freeze(now_iso, zone)
        for text in WHEN_INPUTS:
            got = events.parse_when(text)
            out.append(
                {
                    "now": now_iso,
                    "zone": zone,
                    "input": text,
                    "due": utc(got[0]) if got else None,
                    "allDay": got[1] if got else None,
                }
            )
    return out


TEXT_INPUTS = [
    "plain", "a\x00b\tc\nd", "  lots   of space  here ", "&amp;&lt;&gt;&quot;&#39;",
    "&amp", "&ampfoo", "&notit;", "&notin;", "&#x41;&#65;&#0;&#x80;&#150;&#xD800;&#1114112;",
    "&#12abc", "&#x;", "&#;", "&;", "& alone", "caf&eacute; &Eacute;cole", "&AMP;", "&AElig",
    "&unknownentity;", "&lt3", "x &amp;amp; y", "\r\ncarriage", "\x7fdel\x1funit", "zero​width",
    "&nbsp;x&nbsp;", "emoji 😀 &#128512;", "&#xFFFE;&#x1FFFF;&#11;", "a&amp;b&amp;c",
    "tab\tin\ttitle", "&ThickSpace;", "&NotEqualTilde;", "&fjlig;",
]


def text_cases() -> list[dict]:
    return [
        {
            "input": s,
            "clean": ical.clean_text(s),
            "deep": ical._deep_unescape(s),
            "unescape": ical.unescape(s),
            "repr": repr(s),
        }
        for s in TEXT_INPUTS + [r"Reading\, ch. 4-5", r"a\nb", r"a\\nb", r"x\;y\Nz\q"]
    ]


def gradescope_cases(pages: list[Path], dashboards: list[Path]) -> dict:
    courses_out = []
    for path in dashboards:
        doc = BeautifulSoup(path.read_text(), "html.parser")
        for all_terms in (False, True):
            courses_out.append(
                {
                    "file": path.name,
                    "allTerms": all_terms,
                    "courses": gradescope.parse_courses(doc, all_terms),
                }
            )
    assignments_out = []
    course = {"id": "100001", "name": "CS 25100", "url": "https://www.gradescope.com/courses/100001"}
    for path in pages:
        doc = BeautifulSoup(path.read_text(), "html.parser")
        this = dict(course)
        if path.stem.startswith("course_"):
            cid = path.stem.split("_", 1)[1]
            this = {"id": cid, "name": f"C{cid}", "url": f"https://www.gradescope.com/courses/{cid}"}
        rows = gradescope.parse_assignments(doc, this)
        freeze("2026-09-24T10:00:00-04:00", "America/Indiana/Indianapolis")
        items = sources.gradescope_items(rows)
        assignments_out.append(
            {
                "file": path.name,
                "course": this,
                "rows": rows,
                "items": [item_json(i) for i in items],
                "autoComplete": sorted(sources.gradescope_auto_complete_keys(rows)),
                "submitted": [gradescope.is_submitted(r["status"]) for r in rows],
                "closed": [gradescope.is_closed(r["status"]) for r in rows],
            }
        )
    return {"courses": courses_out, "assignments": assignments_out}


NORMALIZE_INPUTS = [
    "2026-09-07 23:59:00 -0400", "2026-09-07T23:59:00Z", "2026-09-07T23:59", "2026-09-07 23:59:00.123 +05:30",
    "2026-09-07T23:59:00+0000", "2026-09-07", "2026-09-07T23:59:00.123456", "2026-09-07 23:59:00",
    "garbage", "", "2026-09-07T23:59:00 +05", "2026-09-07T23:59:00-04:00",
]


def normalize_cases() -> list[dict]:
    return [{"input": s, "output": gradescope.normalize_datetime(s)} for s in NORMALIZE_INPUTS]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    public_ics = sorted((FIX / "ics").glob("*.ics")) + sorted((FIX / "ics").glob("*.gz"))
    public_html = FIX / "html"

    def dump(path: Path, value) -> None:
        path.write_text(json.dumps(value, indent=1, ensure_ascii=False) + "\n")
        print(f"wrote {path.relative_to(FIX)}")

    dump(OUT / "ics.json", ics_cases(public_ics))
    dump(OUT / "when.json", when_cases())
    dump(OUT / "text.json", text_cases())
    dump(OUT / "normalize.json", normalize_cases())
    dump(
        OUT / "gradescope.json",
        gradescope_cases([public_html / "course.html"], [public_html / "dashboard.html"]),
    )

    if PRIVATE.exists():
        dump(PRIVATE / "ics.json", ics_cases(sorted(PRIVATE.glob("*.ics"))))
        dump(
            PRIVATE / "gradescope.json",
            gradescope_cases(sorted(PRIVATE.glob("course_*.html")), sorted(PRIVATE.glob("dashboard*.html"))),
        )


if __name__ == "__main__":
    main()
