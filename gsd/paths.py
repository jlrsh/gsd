"""XDG-aware filesystem locations for GSD data."""

from __future__ import annotations

import os
from pathlib import Path

APP = "gsd"


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
