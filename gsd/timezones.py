"""Local IANA timezone detection and runtime timezone selection."""

from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


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
LOCAL = (
    ZoneInfo(LOCAL_TIMEZONE) if LOCAL_TIMEZONE else datetime.now().astimezone().tzinfo
)


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
