"""Calendar and plugin fetching with background refresh and last-good caches."""

from __future__ import annotations

import gzip
import hashlib
import os
import queue
import re
import threading
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

from . import timezones
from .ical import clean_text, decode_ics, looks_like_calendar
from .models import Feed, Item
from .paths import GRADESCOPE_CACHE, GRADESCOPE_COOKIES
from .plugins import gradescope

APP = "gsd"


def fetch_text(url: str, timeout: int) -> str:
    """Fetch one feed and decode it.  Raises on transport or content failure."""
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://") :]
    elif url.startswith("webcals://"):
        url = "https://" + url[len("webcals://") :]

    if not re.match(r"^\w+://", url):
        raw = Path(url).expanduser().read_bytes()
    else:
        req = urllib.request.Request(
            url,
            headers={
                # Plain Python-urllib/x.y gets 403'd by the CDNs in front of some LMSes.
                "User-Agent": f"{APP}/1.0",
                "Accept": "text/calendar, text/plain, */*",
            },
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    if raw[:2] == b"\x1f\x8b":  # some servers gzip regardless
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
            due = due.replace(tzinfo=timezones.LOCAL)
        identity = f"{row.get('course_id', '')}:{row.get('key', row.get('title', ''))}"
        key = hashlib.sha1(f"gradescope\x00{identity}".encode()).hexdigest()[:20]
        title = clean_text(
            f"{row.get('course', '')} — {row.get('title', '(untitled)')}"
        )
        items.append(
            Item(
                key=key,
                title=title,
                due=due,
                all_day=False,
                link=row.get("url"),
                source="Gradescope",
            )
        )
    return items


def start_fetches(
    feeds: list[Feed],
    timeout: int,
    grade_config: dict | None = None,
    horizon_days: int = 120,
) -> queue.Queue:
    """Kick off one daemon thread per active source."""
    q: queue.Queue = queue.Queue()

    def work(feed: Feed) -> None:
        try:
            text = fetch_text(feed.url, timeout)
        except Exception as exc:  # network, DNS, TLS, bad path, HTML
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
                rows = gradescope.fetch(
                    grade_config, GRADESCOPE_COOKIES, timeout, horizon_days
                )
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
