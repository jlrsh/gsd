"""Terminal-safe text width, clipping, and relative-time helpers."""

from __future__ import annotations

import time
import unicodedata


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
