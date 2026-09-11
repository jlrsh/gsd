"""Shared data models used across configuration, sources, and the UI."""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

from . import paths, timezones


@dataclass
class Feed:
    url: str
    name: str
    enabled: bool = True

    @property
    def cache_path(self) -> Path:
        digest = hashlib.sha256(self.url.encode()).hexdigest()[:24]
        return paths.CACHE_DIR / f"{digest}.ics"


@dataclass
class Item:
    key: str
    title: str
    due: datetime | None  # None for an undated VTODO
    all_day: bool
    link: str | None = None
    source: str = "manual"
    manual: bool = False
    checked: bool = False
    completed_at: str | None = None

    @property
    def local_due(self) -> datetime | None:
        return self.due.astimezone(timezones.LOCAL) if self.due else None

    @property
    def day(self) -> date | None:
        due = self.local_due
        return due.date() if due else None

    @property
    def sort_key(self) -> tuple:
        due = self.local_due
        if due is None:
            return (1, datetime.max.replace(tzinfo=timezones.LOCAL), self.title.lower())
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
                due = due.replace(tzinfo=timezones.LOCAL)
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


@dataclass
class FeedStatus:
    name: str
    ok: bool = False
    error: str | None = None
    cached_at: float | None = None
    pending: bool = True


@dataclass
class Row:
    kind: str  # "item" | "header" | "blank" | "rule"
    text: str = ""
    item: Item | None = None
    style: str = ""  # "section" | "day" | "overdue"
