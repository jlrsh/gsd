"""Curses application, rendering, input handling, and source management."""

from __future__ import annotations

import curses
import queue
import threading
import time
import uuid
import webbrowser
from datetime import date, datetime

from . import timezones
from .config import configure_timezone, edit_config, set_source_enabled
from .events import build_rows, parse_when
from .ical import clean_text, items_from_ics
from .models import Feed, FeedStatus, Item, Row
from .paths import CONFIG_PATH, GRADESCOPE_CACHE, STATE_PATH
from .plugins import gradescope
from .sources import GRADESCOPE_SOURCE, gradescope_items, read_cache, start_fetches
from .state import prune_completed, save_state
from .text import dtrim, dwidth, rel_time

HELP_LINES = [
    ("j / k, ↓ / ↑", "move between assignments"),
    ("g / G", "jump to first / last"),
    ("space", "check or uncheck"),
    ("enter", "open the event's first link"),
    ("a", "add an assignment by hand"),
    ("e / d", "edit / delete a manual assignment"),
    ("r", "refresh all feeds"),
    ("c", "enable or disable sources"),
    ("?", "this help"),
    ("q", "quit, filing checked items under Completed"),
]


class App:
    def __init__(self, stdscr, feeds: list[Feed], settings: dict, state: dict):
        self.stdscr = stdscr
        self.all_feeds = feeds
        self.feeds = [feed for feed in feeds if feed.enabled]
        self.settings = settings
        self.grade_config = settings.get("gradescope") or {
            "enabled": False,
            "email": "",
        }
        self.state = state

        self.completed: dict[str, dict] = state["completed"]
        self.checked: set[str] = set(self.completed) | set(state.get("checked", []))
        self.manual: list[Item] = [
            it for it in (Item.from_json(d) for d in state.get("manual", [])) if it
        ]
        for it in self.manual:
            it.manual = True

        self.feed_items: dict[str, list[Item]] = {}
        self.status: dict[str, FeedStatus] = {
            f.url: FeedStatus(name=f.name) for f in self.feeds
        }
        if self.grade_config.get("enabled"):
            self.status[GRADESCOPE_SOURCE] = FeedStatus(name="Gradescope")
        self.queue: queue.Queue | None = None
        self.message = ""
        self.message_until = 0.0

        self.rows: list[Row] = []
        self.main_start = 0
        self.cursor = 0
        self.scroll = 0
        self.dirty = True

    # -- data ------------------------------------------------------------

    def load_caches(self) -> None:
        for feed in self.feeds:
            text, mtime = read_cache(feed)
            if text is None:
                continue
            try:
                self.feed_items[feed.url] = items_from_ics(
                    text, feed, self.settings["horizon_days"]
                )
            except Exception:
                self.feed_items[feed.url] = []
            self.status[feed.url].cached_at = mtime
        if self.grade_config.get("enabled"):
            rows, mtime = gradescope.read_cache(GRADESCOPE_CACHE)
            self.feed_items[GRADESCOPE_SOURCE] = gradescope_items(rows)
            self.status.setdefault(
                GRADESCOPE_SOURCE, FeedStatus(name="Gradescope")
            ).cached_at = mtime

    def refresh(self) -> None:
        for st in self.status.values():
            st.pending = True
        self.queue = start_fetches(
            self.feeds,
            self.settings["fetch_timeout"],
            self.grade_config,
            self.settings["horizon_days"],
        )

    def has_sources(self) -> bool:
        return bool(self.feeds or self.grade_config.get("enabled"))

    def drain(self) -> bool:
        """Absorb finished fetches.  Returns True if anything changed."""
        if self.queue is None:
            return False
        changed = False
        while True:
            try:
                feed, text, err = self.queue.get_nowait()
            except queue.Empty:
                break
            source_id = feed if feed == GRADESCOPE_SOURCE else feed.url
            st = self.status[source_id]
            st.pending = False
            if err is None:
                try:
                    if feed == GRADESCOPE_SOURCE:
                        self.feed_items[source_id] = gradescope_items(text)
                    else:
                        self.feed_items[source_id] = items_from_ics(
                            text, feed, self.settings["horizon_days"]
                        )
                    st.ok, st.error, st.cached_at = True, None, time.time()
                except Exception as exc:
                    st.ok, st.error = False, f"parse: {type(exc).__name__}"
            else:
                st.ok, st.error = False, err
            changed = True
        if all(not s.pending for s in self.status.values()):
            self.queue = None
        return changed

    def live_items(self) -> dict[str, Item]:
        """Everything currently sourced from a feed or the manual list."""
        live: dict[str, Item] = {}
        for items in self.feed_items.values():
            for it in items:
                live.setdefault(it.key, it)
        for it in self.manual:
            live[it.key] = it
        return live

    def rebuild(self, keep_key: str | None = None, keep_screen_row: int = 0) -> None:
        live = self.live_items()
        main = [it for key, it in live.items() if key not in self.completed]
        for it in main:
            it.checked = it.key in self.checked

        done: list[Item] = []
        for key, snap in self.completed.items():
            it = Item.from_json(snap)
            if it is None:
                continue
            it.checked = key in self.checked
            done.append(it)

        self.rows, self.main_start = build_rows(done, main)

        # Re-anchor the cursor on the item it was on, not on a row number.
        if keep_key is not None:
            found = next(
                (
                    i
                    for i, r in enumerate(self.rows)
                    if r.kind == "item" and r.item and r.item.key == keep_key
                ),
                None,
            )
            if found is not None:
                self.cursor = found
                self.scroll = max(0, found - keep_screen_row)
            else:
                self.cursor = min(self.cursor, len(self.rows) - 1)
                self.snap_to_item(+1) or self.snap_to_item(-1)
        else:
            self.cursor = self.main_start
            self.scroll = self.main_start
            if not self.snap_to_item(+1):
                self.snap_to_item(-1)
        self.dirty = True

    # -- cursor ----------------------------------------------------------

    def item_rows(self) -> list[int]:
        return [i for i, r in enumerate(self.rows) if r.kind == "item"]

    def current(self) -> Item | None:
        if 0 <= self.cursor < len(self.rows):
            row = self.rows[self.cursor]
            if row.kind == "item":
                return row.item
        return None

    def snap_to_item(self, direction: int) -> bool:
        """Move the cursor onto the nearest item row in `direction`."""
        i = max(0, min(self.cursor, len(self.rows) - 1))
        while 0 <= i < len(self.rows):
            if self.rows[i].kind == "item":
                self.cursor = i
                return True
            i += direction
        return False

    def move(self, delta: int) -> None:
        items = self.item_rows()
        if not items:
            return
        after = [i for i in items if i > self.cursor]
        before = [i for i in items if i < self.cursor]
        if delta > 0 and after:
            self.cursor = after[0]
        elif delta < 0 and before:
            self.cursor = before[-1]
        self.dirty = True

    # -- drawing ---------------------------------------------------------

    def clamp(self, body: int) -> None:
        """Keep the viewport legal.

        The lower bound of `max_scroll` is `main_start`, not `len(rows)-body`:
        otherwise a short main list would drag the Completed section down into
        view, which is exactly what it must not do.
        """
        max_scroll = max(self.main_start, len(self.rows) - body)
        self.scroll = max(0, min(self.scroll, max_scroll))

    def ensure_visible(self, body: int) -> None:
        if self.cursor < self.scroll:
            self.scroll = self.cursor
            # Pull the day header (and its blank line) along for context.
            back = 0
            while (
                back < 2
                and self.scroll > 0
                and self.rows[self.scroll - 1].kind in ("header", "blank")
            ):
                self.scroll -= 1
                back += 1
            # Nothing selectable remains above: show the very top, so the
            # "Completed" banner is actually reachable.
            if not any(r.kind == "item" for r in self.rows[: self.scroll]):
                self.scroll = 0
        elif self.cursor >= self.scroll + body:
            self.scroll = self.cursor - body + 1

    def attr(self, name: str) -> int:
        return self.pairs.get(name, curses.A_NORMAL)

    def setup_colors(self) -> None:
        self.pairs = {}
        if not curses.has_colors():
            self.pairs = {
                "dim": curses.A_DIM,
                "header": curses.A_BOLD,
                "overdue": curses.A_BOLD,
                "accent": curses.A_NORMAL,
                "done": curses.A_DIM,
            }
            return
        curses.start_color()
        try:
            curses.use_default_colors()
        except curses.error:
            pass
        curses.init_pair(1, curses.COLOR_BLUE, -1)
        curses.init_pair(2, curses.COLOR_RED, -1)
        curses.init_pair(3, curses.COLOR_CYAN, -1)
        curses.init_pair(4, curses.COLOR_GREEN, -1)
        self.pairs = {
            "dim": curses.A_DIM,
            "header": curses.color_pair(1) | curses.A_BOLD,
            "overdue": curses.color_pair(2) | curses.A_BOLD,
            "accent": curses.color_pair(3),
            "done": curses.color_pair(4) | curses.A_DIM,
        }

    def put(self, y: int, x: int, text: str, attr: int, w: int) -> None:
        """Write clipped to w-1 columns.  Overflow silently wraps in curses."""
        room = w - 1 - x
        if room <= 0 or not text:
            return
        try:
            self.stdscr.addstr(y, x, dtrim(text, room), attr)
        except curses.error:
            pass

    def item_line(self, it: Item, w: int) -> tuple[str, str, str]:
        box = "[x]" if it.checked else "[ ]"
        if not it.checked and it.day is not None and it.day < date.today():
            due = it.local_due
            assert due is not None
            clock = f"{due:%m/%d}"
        else:
            clock = it.time_label()
        prefix = f"{box} {clock:>5}  "
        source = it.source if w >= 56 else ""
        tail = f"  {source}" if source else ""
        room = (w - 1) - dwidth(prefix) - dwidth(tail)
        title = it.title + ("  ↗" if it.link else "")
        return prefix, dtrim(title, max(4, room)), tail

    def draw_row(self, y: int, row: Row, w: int, selected: bool) -> None:
        if row.kind == "blank":
            return
        if row.kind == "rule":
            self.put(y, 1, "─" * max(0, w - 3), self.attr("dim"), w)
            return
        if row.kind == "header":
            if row.style == "section":
                label = f"── {row.text} "
                self.put(
                    y,
                    1,
                    label + "─" * max(0, w - 4 - dwidth(label)),
                    self.attr("done"),
                    w,
                )
            else:
                style = "overdue" if row.style == "overdue" else "header"
                self.put(y, 1, row.text, self.attr(style), w)
            return

        it = row.item
        assert it is not None
        prefix, title, tail = self.item_line(it, w)
        base = self.attr("done") if it.checked else curses.A_NORMAL
        self.put(y, 1, prefix, base | (curses.A_DIM if it.checked else 0), w)
        self.put(y, 1 + dwidth(prefix), title, base, w)
        if tail:
            self.put(y, w - 1 - dwidth(tail) + 1, tail.strip(), self.attr("dim"), w)
        if selected:
            # chgat extends the highlight to the edge without writing cells,
            # which would wrap the line.
            try:
                self.stdscr.chgat(y, 0, -1, curses.A_REVERSE)
            except curses.error:
                pass

    def status_line(self) -> tuple[str, str]:
        if self.message and time.time() < self.message_until:
            return self.message, self.gradescope_status()
        today = date.today()
        main_open = [
            r.item
            for r in self.rows[self.main_start :]
            if r.kind == "item" and r.item and not r.item.checked
        ]
        overdue = sum(1 for it in main_open if it.day is not None and it.day < today)
        bits = [f"{len(main_open)} open"]
        if overdue:
            bits.append(f"{overdue} overdue")
        feed_status = [self.status[f.url] for f in self.feeds]
        if feed_status:
            failed = [s for s in feed_status if not s.pending and s.error]
            pending = any(s.pending for s in feed_status)
            newest = max((s.cached_at or 0 for s in feed_status), default=0)
            if pending:
                bits.append("fetching…")
            elif failed:
                bits.append(f"{failed[0].name}: {failed[0].error}")
            else:
                bits.append(f"updated {rel_time(newest or None)}")
        elif not self.grade_config.get("enabled"):
            bits.append(f"no feeds — see {CONFIG_PATH}")
        return " · ".join(bits), self.gradescope_status()

    def gradescope_status(self) -> str:
        if not self.grade_config.get("enabled"):
            return ""
        st = self.status.get(GRADESCOPE_SOURCE)
        if st is None:
            return "Gradescope: never synced"
        if st.pending:
            return "Gradescope: syncing…"
        if st.error:
            return f"Gradescope: {st.error}"
        return f"Gradescope synced {rel_time(st.cached_at)}"

    def draw(self) -> None:
        h, w = self.stdscr.getmaxyx()
        self.stdscr.erase()
        if h < 3 or w < 24:
            self.put(0, 0, "terminal too small", curses.A_NORMAL, w)
            self.stdscr.refresh()
            return
        body = h - 1
        self.ensure_visible(body)
        self.clamp(body)
        for i in range(body):
            idx = self.scroll + i
            if idx >= len(self.rows):
                break
            self.draw_row(i, self.rows[idx], w, selected=(idx == self.cursor))
        left, right = self.status_line()
        right = dtrim(right, max(0, w // 2))
        right_width = dwidth(right)
        left_room = max(0, w - 3 - right_width)
        left = dtrim(left, left_room)
        try:
            self.stdscr.addstr(h - 1, 0, " " * (w - 1), self.attr("dim"))
            self.stdscr.addstr(h - 1, 1, left, self.attr("dim"))
            if right:
                self.stdscr.addstr(h - 1, w - 1 - right_width, right, self.attr("dim"))
        except curses.error:
            pass
        self.stdscr.refresh()

    def notify(self, text: str, seconds: float = 3.0) -> None:
        self.message = text
        self.message_until = time.time() + seconds
        self.dirty = True

    # -- input -----------------------------------------------------------

    def read_key(self):
        """Return a str for text, an int for special keys, or None on timeout.

        Prefers get_wch (widechar ncurses); falls back to assembling UTF-8 from
        raw getch bytes on builds that lack it.
        """
        try:
            ch = self.stdscr.get_wch()
        except curses.error:
            return None  # timeout tick
        except AttributeError:
            ch = self.stdscr.getch()
            if ch == -1:
                return None
            if 0x80 <= ch <= 0xFF:
                if ch >= 0xF0:
                    need = 3
                elif ch >= 0xE0:
                    need = 2
                elif ch >= 0xC0:
                    need = 1
                else:
                    need = 0
                buf = bytearray([ch])
                for _ in range(need):
                    nxt = self.stdscr.getch()
                    if nxt == -1:
                        break
                    buf.append(nxt)
                return buf.decode("utf-8", errors="replace")
            if 32 <= ch < 127:
                return chr(ch)
            return ch
        return ch

    def swallow_escape_sequence(self) -> None:
        """Eat a CSI sequence (e.g. a bracketed-paste marker) after a bare ESC."""
        self.stdscr.timeout(20)
        try:
            nxt = self.stdscr.getch()
            if nxt not in (ord("["), ord("O")):
                return
            for _ in range(32):
                b = self.stdscr.getch()
                if b == -1 or 0x40 <= b <= 0x7E:
                    return
        finally:
            self.stdscr.timeout(-1)

    def prompt(self, label: str, initial: str = "") -> str | None:
        """Read one line on the bottom row.  ESC cancels and returns None."""
        buf = list(initial)
        h, w = self.stdscr.getmaxyx()
        self.stdscr.timeout(-1)
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        try:
            while True:
                h, w = self.stdscr.getmaxyx()
                text = "".join(buf)
                shown = label + text
                # Horizontally scroll the field once it outgrows the line.
                while dwidth(shown) > w - 2 and shown:
                    text_start = len(shown) - (w - 2)
                    shown = "…" + shown[max(0, text_start) + 1 :]
                try:
                    self.stdscr.move(h - 1, 0)
                    self.stdscr.clrtoeol()
                    self.stdscr.addnstr(h - 1, 0, shown, w - 1, curses.A_BOLD)
                    self.stdscr.move(h - 1, min(dwidth(shown), w - 1))
                except curses.error:
                    pass
                self.stdscr.refresh()

                key = self.read_key()
                if key is None:
                    continue
                if key == curses.KEY_RESIZE or key == "\x0c":
                    self.stdscr.clear()
                    self.draw()
                    continue
                if key == "\x1b":
                    self.swallow_escape_sequence()
                    return None
                if key in ("\n", "\r") or key in (curses.KEY_ENTER, 10, 13):
                    return "".join(buf)
                if key in ("\x7f", "\b", "\x08") or key in (
                    curses.KEY_BACKSPACE,
                    263,
                    127,
                    8,
                ):
                    if buf:
                        buf.pop()
                    continue
                if key == "\x15":  # ctrl-u
                    buf.clear()
                    continue
                if isinstance(key, str) and key.isprintable():
                    buf.append(key)
        finally:
            try:
                curses.curs_set(0)
            except curses.error:
                pass

    def show_help(self) -> None:
        h, w = self.stdscr.getmaxyx()
        self.stdscr.erase()
        self.put(0, 1, "gsd — keys", self.attr("header"), w)
        for i, (keys, what) in enumerate(HELP_LINES):
            if 2 + i >= h - 1:
                break
            self.put(2 + i, 2, f"{keys:<16}", self.attr("accent"), w)
            self.put(2 + i, 20, what, curses.A_NORMAL, w)
        row = min(h - 2, 3 + len(HELP_LINES))
        self.put(row, 2, f"config  {CONFIG_PATH}", self.attr("dim"), w)
        self.put(row + 1, 2, f"state   {STATE_PATH}", self.attr("dim"), w)
        self.put(
            row + 2,
            2,
            f"timezone {self.settings.get('resolved_timezone') or timezones.LOCAL}",
            self.attr("dim"),
            w,
        )
        self.put(h - 1, 1, "any key to return", self.attr("dim"), w)
        self.stdscr.refresh()
        self.stdscr.timeout(-1)
        self.read_key()
        self.dirty = True

    def show_sources(self) -> None:
        """Small config UI for toggling calendar feeds and bundled plugins."""
        entries = [
            (
                "gradescope",
                GRADESCOPE_SOURCE,
                "Gradescope plugin",
                bool(self.grade_config.get("enabled")),
            )
        ]
        entries.extend(
            ("feed", feed.url, f"Calendar · {feed.name}", feed.enabled)
            for feed in self.all_feeds
        )
        selected = 0
        changed = False
        self.stdscr.timeout(-1)
        while True:
            h, w = self.stdscr.getmaxyx()
            self.stdscr.erase()
            self.put(0, 1, "Sources", self.attr("header"), w)
            self.put(
                1,
                1,
                "space toggle · t timezone · e edit config · q/esc done",
                self.attr("dim"),
                w,
            )
            zone = self.settings.get("resolved_timezone") or str(timezones.LOCAL)
            self.put(2, 1, f"Timezone: {zone}", self.attr("dim"), w)
            for idx, (_kind, _identifier, label, enabled) in enumerate(
                entries[: max(0, h - 5)]
            ):
                line = f"[{'x' if enabled else ' '}] {label}"
                self.put(idx + 4, 2, line, curses.A_NORMAL, w)
                if idx == selected:
                    try:
                        self.stdscr.chgat(idx + 4, 0, -1, curses.A_REVERSE)
                    except curses.error:
                        pass
            self.put(h - 1, 1, str(CONFIG_PATH), self.attr("dim"), w)
            self.stdscr.refresh()
            key = self.read_key()
            if key in ("q", "Q", "\x1b", "\n", "\r"):
                break
            if key in ("j", "J") or key == curses.KEY_DOWN:
                selected = min(len(entries) - 1, selected + 1)
            elif key in ("k", "K") or key == curses.KEY_UP:
                selected = max(0, selected - 1)
            elif key == " " and entries:
                kind, identifier, label, enabled = entries[selected]
                try:
                    set_source_enabled(kind, identifier, not enabled)
                except Exception as exc:
                    self.notify(f"config: {type(exc).__name__}")
                    break
                entries[selected] = (kind, identifier, label, not enabled)
                if kind == "gradescope":
                    self.grade_config["enabled"] = not enabled
                else:
                    next(
                        f for f in self.all_feeds if f.url == identifier
                    ).enabled = not enabled
                changed = True
            elif key in ("e", "E"):
                # Leave curses before invoking the user's editor.
                curses.endwin()
                edit_config()
                try:
                    curses.reset_prog_mode()
                except curses.error:
                    pass
                self.stdscr.clear()
                self.stdscr.refresh()
                self.notify("config edited; restart gsd to reload it", seconds=5)
                return
            elif key in ("t", "T"):
                raw = self.prompt(
                    "Timezone (IANA name or auto): ",
                    str(self.settings.get("timezone") or "auto"),
                )
                if raw is None:
                    continue
                try:
                    resolved = configure_timezone(raw)
                except ValueError as exc:
                    self.notify(str(exc), seconds=5)
                    return
                self.settings["timezone"] = (
                    "auto" if raw.strip().lower() in ("", "auto") else raw.strip()
                )
                self.settings["resolved_timezone"] = resolved
                changed = True
        if changed:
            self.apply_source_changes()
            self.notify("source settings saved")
        self.dirty = True

    def apply_source_changes(self) -> None:
        """Apply source-manager toggles immediately without restarting."""
        # Results from the previous source set are no longer authoritative.
        # Its daemon workers may finish, but their now-unreferenced queue is safe.
        self.queue = None
        self.feeds = [feed for feed in self.all_feeds if feed.enabled]
        active = {feed.url for feed in self.feeds}
        if self.grade_config.get("enabled"):
            active.add(GRADESCOPE_SOURCE)
        self.feed_items = {
            key: value for key, value in self.feed_items.items() if key in active
        }
        old = self.status
        self.status = {
            feed.url: old.get(feed.url, FeedStatus(name=feed.name))
            for feed in self.feeds
        }
        if self.grade_config.get("enabled"):
            self.status[GRADESCOPE_SOURCE] = old.get(
                GRADESCOPE_SOURCE, FeedStatus(name="Gradescope")
            )
        self.load_caches()
        self.rebuild()
        if self.can_fetch and self.has_sources():
            self.refresh()

    def open_link(self, it: Item) -> None:
        if not it.link:
            self.notify("no link on this event")
            return
        try:
            browser = webbrowser.get()
        except webbrowser.Error:
            self.notify("no browser available")
            return
        if isinstance(browser, webbrowser.GenericBrowser):
            # A terminal browser would take over the screen and block on wait().
            self.notify(f"link: {it.link}", seconds=8)
            return
        threading.Thread(target=lambda: browser.open(it.link), daemon=True).start()
        self.notify("opening link…", seconds=1.5)
        self.stdscr.redrawwin()

    # -- actions ---------------------------------------------------------

    def screen_row(self) -> int:
        return max(0, self.cursor - self.scroll)

    def toggle(self) -> None:
        it = self.current()
        if it is None:
            return
        it.checked = not it.checked
        if it.checked:
            self.checked.add(it.key)
        else:
            self.checked.discard(it.key)
        # Only the glyph changes; nothing reflows until quit.
        self.state["checked"] = sorted(self.checked)
        save_state(self.state)
        self.dirty = True

    def add_item(self) -> None:
        title = self.prompt("Title: ")
        if title is None or not title.strip():
            return
        while True:
            raw = self.prompt("Due (today / fri / 9-12 / 2026-09-12, +time): ")
            if raw is None:
                return
            when = parse_when(raw)
            if when is not None:
                break
            self.notify("could not read that date — try 'fri' or 2026-09-12")
            self.draw()
        due, all_day = when
        item = Item(
            key=uuid.uuid4().hex,
            title=clean_text(title),
            due=due,
            all_day=all_day,
            source="manual",
            manual=True,
        )
        self.manual.append(item)
        self.persist_manual()
        self.rebuild(keep_key=item.key, keep_screen_row=self.screen_row())
        self.notify(f"added for {due:%a %b %-d}")

    def edit_item(self) -> None:
        it = self.current()
        if it is None:
            return
        if not it.manual:
            self.notify("only manual items can be edited")
            return
        title = self.prompt("Title: ", it.title)
        if title is None or not title.strip():
            return
        target = next((m for m in self.manual if m.key == it.key), None)
        if target is None:
            return
        target.title = clean_text(title)
        self.persist_manual()
        self.rebuild(keep_key=it.key, keep_screen_row=self.screen_row())

    def delete_item(self) -> None:
        it = self.current()
        if it is None:
            return
        if not it.manual:
            self.notify("only manual items can be deleted")
            return
        answer = self.prompt(f"Delete “{dtrim(it.title, 40)}”? [y/N] ")
        if not answer or answer.strip().lower() not in ("y", "yes"):
            return
        self.manual = [m for m in self.manual if m.key != it.key]
        self.checked.discard(it.key)
        self.completed.pop(it.key, None)
        self.persist_manual()
        self.rebuild()
        self.notify("deleted")

    def persist_manual(self) -> None:
        self.state["manual"] = [m.to_json() for m in self.manual]
        self.state["checked"] = sorted(self.checked)
        save_state(self.state)

    def reconcile_and_save(self) -> None:
        """Quit-time sweep: checked items become Completed, unchecked return."""
        live = self.live_items()
        now = datetime.now(timezones.LOCAL).isoformat(timespec="seconds")
        new_completed: dict[str, dict] = {}

        for key in self.checked:
            previous = self.completed.get(key)
            if previous is not None:
                snap = dict(previous)
                snap.setdefault("completed_at", now)
            elif key in live:
                item = live[key]
                snap = item.to_json()
                snap["completed_at"] = now
            else:
                continue
            new_completed[key] = snap

        # An item unchecked inside Completed whose feed entry is gone would
        # otherwise vanish; keep it by turning it into a manual item.
        manual_keys = {m.key for m in self.manual}
        for key, snap in self.completed.items():
            if key in self.checked or key in live or key in manual_keys:
                continue
            restored = Item.from_json(snap)
            if restored is None:
                continue
            restored.manual = True
            restored.source = snap.get("source") or "manual"
            restored.completed_at = None
            self.manual.append(restored)

        self.completed = prune_completed(new_completed, self.settings["retention_days"])
        cap = 500
        if len(self.completed) > cap:
            ordered = sorted(
                self.completed.items(),
                key=lambda kv: kv[1].get("completed_at") or "",
                reverse=True,
            )
            self.completed = dict(ordered[:cap])

        self.state["completed"] = self.completed
        self.state["manual"] = [m.to_json() for m in self.manual]
        self.state["checked"] = sorted(self.completed)
        save_state(self.state)

    # -- loop ------------------------------------------------------------

    def run(self, fetch: bool = True) -> None:
        curses.curs_set(0)
        try:
            curses.set_escdelay(25)
        except (AttributeError, curses.error):
            pass
        self.setup_colors()
        self.load_caches()
        self.rebuild()
        self.can_fetch = fetch
        if self.has_sources() and fetch:
            self.refresh()
        elif not fetch:
            for status in self.status.values():
                status.pending = False

        while True:
            self.stdscr.timeout(150 if self.queue is not None else 1000)
            if self.dirty:
                self.draw()
                self.dirty = False
            key = self.read_key()

            if self.drain():
                it = self.current()
                self.rebuild(
                    keep_key=it.key if it else None, keep_screen_row=self.screen_row()
                )
            if self.message and time.time() >= self.message_until:
                self.message = ""
                self.dirty = True

            if key is None:
                continue
            if key == curses.KEY_RESIZE:
                curses.update_lines_cols()
                self.stdscr.clear()  # erase() leaves stale cells on shrink
                self.dirty = True
                continue
            if key in ("q", "Q"):
                self.reconcile_and_save()
                return
            if key in ("j", "J") or key == curses.KEY_DOWN:
                self.move(+1)
            elif key in ("k", "K") or key == curses.KEY_UP:
                self.move(-1)
            elif key == "g" or key == curses.KEY_HOME:
                items = self.item_rows()
                if items:
                    self.cursor = items[0]
                    self.dirty = True
            elif key == "G" or key == curses.KEY_END:
                items = self.item_rows()
                if items:
                    self.cursor = items[-1]
                    self.dirty = True
            elif key in (curses.KEY_NPAGE, curses.KEY_PPAGE):
                # Step a screenful of *items*; ensure_visible owns the scroll.
                step = max(1, self.stdscr.getmaxyx()[0] // 2)
                for _ in range(step):
                    self.move(+1 if key == curses.KEY_NPAGE else -1)
            elif key == " ":
                self.toggle()
            elif key in ("\n", "\r") or key in (curses.KEY_ENTER, 10, 13):
                it = self.current()
                if it is not None:
                    self.open_link(it)
            elif key == "a":
                self.add_item()
            elif key == "e":
                self.edit_item()
            elif key == "d":
                self.delete_item()
            elif key == "r":
                if self.has_sources() and self.can_fetch:
                    self.refresh()
                    self.notify("refreshing…", seconds=1.5)
                else:
                    self.notify(f"no sources configured — {CONFIG_PATH}")
            elif key == "c":
                self.show_sources()
            elif key == "?":
                self.show_help()
