"""TOML configuration loading and targeted, comment-preserving edits."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess

import tomllib

from . import timezones
from .models import Feed
from .paths import CACHE_DIR, CONFIG_DIR, CONFIG_PATH, DATA_DIR

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

DEFAULTS = {
    "horizon_days": 120,
    "retention_days": 30,
    "fetch_timeout": 10,
    "timezone": "auto",
}


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
        feeds.append(
            Feed(url=url, name=name, enabled=entry.get("enabled") is not False)
        )
    plugin_data = data.get("plugins") or {}
    grade = plugin_data.get("gradescope") or {}
    settings["gradescope"] = {
        "enabled": grade.get("enabled") is True,
        "email": str(grade.get("email") or "").strip(),
        "all_terms": grade.get("all_terms") is True,
        "skip_submitted": grade.get("skip_submitted") is True,
    }
    settings["resolved_timezone"] = timezones.select_local_timezone(
        settings["timezone"]
    )
    return feeds, settings


def _feed_name_from_url(url: str) -> str:
    host = re.sub(r"^\w+://", "", url).split("/")[0]
    return host.split(".")[0] or "feed"


def add_feed_to_config(url: str, name: str | None) -> str:
    ensure_dirs()
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    name = name or _feed_name_from_url(url)
    block = (
        f"\n[[feed]]\nurl = {_toml_string(url)}\n"
        f"name = {_toml_string(name)}\nenabled = true\n"
    )
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
        text = text.rstrip() + (
            "\n\n[plugins.gradescope]\n"
            f"enabled = {'true' if enabled else 'false'}\n"
            f"email = {_toml_string(email)}\n"
            "all_terms = false\nskip_submitted = false\n"
        )
    else:
        end = re.search(r"(?m)^\[", text[header.end() :])
        stop = header.end() + (end.start() if end else len(text[header.end() :]))
        block = text[header.end() : stop]
        block = _set_toml_key(block, "enabled", "true" if enabled else "false")
        block = _set_toml_key(block, "email", _toml_string(email))
        text = text[: header.end()] + block + text[stop:]
    _write_config(text)


def configure_timezone(name: str) -> str:
    """Validate and persist an IANA timezone, or `auto` for system detection."""
    value = "auto" if name.strip().lower() in ("", "auto") else name.strip()
    resolved = timezones.select_local_timezone(value)
    ensure_dirs()
    text = CONFIG_PATH.read_text() if CONFIG_PATH.exists() else DEFAULT_CONFIG
    header = re.search(r"(?m)^\[settings\]\s*$", text)
    if header is None:
        text = f"[settings]\ntimezone = {_toml_string(value)}\n\n" + text
    else:
        next_header = re.search(r"(?m)^\s*\[", text[header.end() :])
        stop = header.end() + next_header.start() if next_header else len(text)
        block = _set_toml_key(
            text[header.end() : stop], "timezone", _toml_string(value)
        )
        text = text[: header.end()] + block + text[stop:]
    _write_config(text)
    return resolved


def _set_toml_key(block: str, key: str, value: str) -> str:
    pattern = re.compile(rf"(?m)^(\s*{re.escape(key)}\s*=\s*)[^#\n]*?(\s*(?:#.*)?)$")
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
        next_header = re.search(r"(?m)^\s*\[", text[start.end() :])
        stop = start.end() + next_header.start() if next_header else len(text)
        block = text[start.end() : stop]
        url_match = re.search(r'(?m)^\s*url\s*=\s*(["\'])(.*?)\1\s*(?:#.*)?$', block)
        if url_match and url_match.group(2) == identifier:
            block = _set_toml_key(block, "enabled", "true" if enabled else "false")
            _write_config(text[: start.end()] + block + text[stop:])
            return
    raise ValueError("calendar feed was not found in config")


def edit_config() -> int:
    ensure_dirs()
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    command = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
    return subprocess.run([*shlex.split(command), str(CONFIG_PATH)]).returncode
