"""Persistent checklist state and completed-item retention."""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta

from . import timezones
from .paths import STATE_PATH

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
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
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
    cutoff = datetime.now(timezones.LOCAL) - timedelta(days=retention_days)
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
            when = when.replace(tzinfo=timezones.LOCAL)
        if when >= cutoff:
            kept[key] = snap
    return kept
