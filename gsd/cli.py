"""Command-line entrypoints and non-interactive output."""

from __future__ import annotations

import argparse
import curses
import sys
from pathlib import Path

from .config import (
    add_feed_to_config,
    configure_gradescope,
    configure_timezone,
    edit_config,
    load_config,
)
from .events import build_rows
from .ical import items_from_ics
from .models import Feed, Item
from .paths import CONFIG_PATH, GRADESCOPE_CACHE, GRADESCOPE_COOKIES
from .plugins import gradescope
from .sources import fetch_text, gradescope_items, read_cache
from .state import load_state
from .ui import App

APP = "gsd"


def collect_items(
    feeds: list[Feed], settings: dict, state: dict, fetch: bool
) -> tuple[list[Item], list[Item]]:
    """Non-interactive gathering, used by --list."""
    items: dict[str, Item] = {}
    for feed in (source for source in feeds if source.enabled):
        text = None
        if fetch:
            try:
                text = fetch_text(feed.url, settings["fetch_timeout"])
                feed.cache_path.write_text(text)
            except Exception:
                text = None
        if text is None:
            text, _ = read_cache(feed)
        if not text:
            continue
        try:
            for it in items_from_ics(text, feed, settings["horizon_days"]):
                items.setdefault(it.key, it)
        except Exception:
            continue
    grade_config = settings.get("gradescope") or {}
    if grade_config.get("enabled"):
        rows = None
        if fetch:
            try:
                rows = gradescope.fetch(
                    grade_config,
                    GRADESCOPE_COOKIES,
                    settings["fetch_timeout"],
                    settings["horizon_days"],
                )
                gradescope.write_cache(GRADESCOPE_CACHE, rows)
            except Exception:
                rows = None
        if rows is None:
            rows, _ = gradescope.read_cache(GRADESCOPE_CACHE)
        for item in gradescope_items(rows):
            items.setdefault(item.key, item)
    for d in state.get("manual", []):
        it = Item.from_json(d)
        if it:
            it.manual = True
            items[it.key] = it
    completed = state.get("completed", {})
    main = [it for k, it in items.items() if k not in completed]
    done = [it for it in (Item.from_json(s) for s in completed.values()) if it]
    return sorted(main, key=lambda i: i.sort_key), sorted(
        done, key=lambda i: i.sort_key
    )


def plain_dump(feeds: list[Feed], settings: dict, state: dict, fetch: bool) -> None:
    main, done = collect_items(feeds, settings, state, fetch)
    rows, main_start = build_rows(done, main)
    for row in rows[main_start:]:
        if row.kind == "blank":
            print()
        elif row.kind == "header":
            print(row.text)
        elif row.kind == "rule":
            continue
        elif row.item is not None:
            it = row.item
            clock = it.time_label()
            print(f"[ ] {clock:>5}  {it.title}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog=APP, description="A minimal assignment TUI with pluggable sources."
    )
    ap.add_argument(
        "--add-feed",
        metavar="URL",
        help="append a calendar feed to the config and exit",
    )
    ap.add_argument("--name", metavar="NAME", help="label for --add-feed")
    ap.add_argument(
        "--list", action="store_true", help="print the list as plain text and exit"
    )
    ap.add_argument(
        "--no-fetch",
        action="store_true",
        help="use cached feeds only, never touch the network",
    )
    ap.add_argument(
        "--edit-config",
        action="store_true",
        help="open config.toml in $VISUAL or $EDITOR",
    )
    ap.add_argument(
        "--timezone", metavar="ZONE", help="set an IANA timezone, or 'auto', and exit"
    )
    ap.add_argument(
        "--gradescope-login",
        metavar="EMAIL",
        help="log into Gradescope and enable its plugin",
    )
    ap.add_argument(
        "--gradescope-import-cookies",
        metavar="FILE",
        help="import a browser cookies.txt for Gradescope",
    )
    ap.add_argument(
        "--gradescope-logout",
        action="store_true",
        help="remove the Gradescope session and stored password",
    )
    args = ap.parse_args(argv)

    if args.timezone is not None:
        try:
            resolved = configure_timezone(args.timezone)
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 2
        print(
            f"timezone: {resolved} ({'auto' if args.timezone.lower() == 'auto' else 'configured'})"
        )
        return 0

    # Parse config before curses starts, so an error prints legibly.
    try:
        feeds, settings = load_config()
    except ValueError as exc:
        print(f"config: {exc}", file=sys.stderr)
        return 2

    if args.edit_config:
        return edit_config()

    if args.add_feed:
        name = add_feed_to_config(args.add_feed, args.name)
        print(f"added feed “{name}” to {CONFIG_PATH}")
        return 0

    if args.gradescope_login:
        try:
            gradescope.login(args.gradescope_login.strip(), GRADESCOPE_COOKIES)
            configure_gradescope(args.gradescope_login.strip(), enabled=True)
        except gradescope.GradescopeError as exc:
            print(f"Gradescope login failed: {exc}", file=sys.stderr)
            return 1
        print(f"Gradescope plugin enabled for {args.gradescope_login.strip()}")
        return 0

    if args.gradescope_import_cookies:
        email = (settings.get("gradescope") or {}).get("email", "")
        try:
            gradescope.import_cookies(
                Path(args.gradescope_import_cookies).expanduser(), GRADESCOPE_COOKIES
            )
        except gradescope.GradescopeError as exc:
            print(f"Cookie import failed: {exc}", file=sys.stderr)
            return 1
        configure_gradescope(email, enabled=True)
        print("Gradescope cookies imported; plugin enabled")
        return 0

    if args.gradescope_logout:
        email = (settings.get("gradescope") or {}).get("email", "")
        deleted = gradescope.delete_password(email) if email else False
        try:
            GRADESCOPE_COOKIES.unlink()
        except FileNotFoundError:
            pass
        configure_gradescope(email, enabled=False)
        print(
            f"Gradescope credentials removed ({'Keychain and session' if deleted else 'session'})"
        )
        return 0

    state = load_state()

    if args.list or not sys.stdout.isatty():
        plain_dump(feeds, settings, state, fetch=not args.no_fetch)
        return 0

    def bootstrap(stdscr):
        App(stdscr, feeds, settings, state).run(fetch=not args.no_fetch)

    try:
        curses.wrapper(bootstrap)
    except KeyboardInterrupt:
        return 130
    return 0
