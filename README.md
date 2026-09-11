# gsd

A minimal terminal checklist for assignments, fed by `.ics` calendars and
source plugins.

It merges any number of published calendar feeds (Canvas, Brightspace, Google
Calendar, Outlook), assignments scraped directly from Gradescope, and items
you type in yourself. Gradescope is consumed directly; no ICS feed is built or
published.

```
 ── Completed ───────────────────────────────────────────────
 Fri Aug 29
 [x] 23:59  CS 381 — HW1  ↗                            Canvas
                                        ↑ scroll up to reach

 Overdue
 [ ] 23:59  CS 381 — HW2  ↗                            Canvas

 Today · Tue Sep 1
 [ ] 14:30  ME 597 — Lab 1  ↗                     Brightspace
 [ ] 23:59  CS 381 — HW3  ↗                            Canvas

 Tomorrow · Wed Sep 2
 [ ] 10:30  ME 597 Lecture  ↗                     Brightspace

 6 open · 1 overdue · updated 2m ago             Gradescope synced 4m ago
```

## Install

Python 3.11+. Install it as a standalone tool, which puts a `gsd` command on
your `PATH` in its own isolated environment:

```sh
uv tool install git+https://github.com/jlrsh/gsd
```

`pipx install git+https://github.com/jlrsh/gsd` does the same thing. Plain pip
works too, if you would rather it land in the current environment:

```sh
pip install git+https://github.com/jlrsh/gsd
```

To upgrade later, `uv tool upgrade gsd` (or `pipx upgrade gsd`). For a checkout
you are editing, `uv tool install --editable .` from the project root.

## Running it

```sh
gsd
```

Add a feed (find the "Calendar Feed" / "Subscribe" URL in your LMS):

```sh
gsd --add-feed "https://…/user_abc123.ics" --name Canvas
```

Local `.ics` paths work too, and `webcal://` URLs are rewritten automatically.

Enable Gradescope and save its password in the macOS Login Keychain:

```sh
gsd --gradescope-login you@example.edu
```

The email goes in GSD's config; the password does not. GSD tries its private
cookie jar first and only reads the password from Keychain when the session
needs renewing. On a non-macOS machine, set `GSD_GRADESCOPE_PASSWORD` instead.
For SSO, MFA, or bot-check accounts, export browser cookies in Netscape format
and run:

```sh
gsd --gradescope-import-cookies ~/Downloads/cookies.txt
```

## Keys

| Key | |
| --- | --- |
| `j` `k` / `↓` `↑` | move |
| `g` / `G` | first / last |
| `space` | check or uncheck |
| `enter` | open the event's first link |
| `a` | add an assignment by hand |
| `e` / `d` | edit / delete a manual assignment |
| `r` | refresh feeds |
| `c` | enable/disable plugins and calendar feeds |
| `?` | help |
| `q` | quit |

Checking an item does **not** move it while you work — nothing jumps around
under the cursor. The sweep happens when you quit: everything checked is filed
under **Completed**, which lives above the main list. Scroll up to reach it.
Uncheck something up there and it returns to its day on the next quit.

Dates for `a` accept `today`, `tomorrow`, `fri`, `+3`, `9/12`, `2026-09-12`,
optionally followed by a time (`fri 5pm`, `9/12 23:59`).

## Files

```
~/.config/gsd/config.toml          feed list and settings
~/.local/share/gsd/state.json      what you have completed, and manual items
~/.local/share/gsd/cache/          last good copy of each feed
~/.local/share/gsd/plugins/        plugin caches and private session cookies
```

Feeds are fetched in the background, so the list paints instantly from cache
and keeps working offline — a feed that fails is reported in the status bar by
its label and its cached copy is used instead.

Press `c` in the TUI for the source manager; `space` toggles the selected
plugin or calendar feed. It patches only that source's `enabled` value, leaving
comments and other hand-edited settings intact. Press `t` to select an IANA
timezone or return to automatic system detection. Press `e` there, or run
`gsd --edit-config`, to open the complete config in `$VISUAL` or
`$EDITOR`.

Gradescope follows the same last-good-cache rule. A failed login, bot check,
parser change, or partial course scrape is shown at the far right of the
bottom bar and does not replace the previous assignment set.

`config.toml`:

```toml
[[feed]]
url  = "https://…ics"
name = "Canvas"
enabled = true

[plugins.gradescope]
enabled = true
email = "you@example.edu"
all_terms = false
skip_submitted = false

[settings]
horizon_days   = 120   # how far ahead to expand recurring events
retention_days = 30    # prune completed items older than this; 0 = keep forever
fetch_timeout  = 10
timezone = "auto"      # or "America/Indiana/Indianapolis"
```

## Other invocations

```sh
gsd --list       # plain text, also used automatically when piped
gsd --no-fetch   # cached feeds only, never touch the network
gsd --edit-config
gsd --timezone America/Indiana/Indianapolis
gsd --timezone auto
gsd --gradescope-logout
```

## Tests

```sh
uv run --extra dev pytest
```

## Code layout

The `gsd` command is the `gsd.cli:main` entry point declared in
`pyproject.toml`; `python -m gsd` runs the same thing. The implementation lives
in the `gsd/` package:

| Module | Responsibility |
| --- | --- |
| `cli.py` | arguments, commands, and plain-text output |
| `ui.py` | curses rendering and interaction |
| `models.py` / `events.py` | shared records, grouping, and manual dates |
| `ical.py` | calendar parsing and recurrence expansion |
| `sources.py` / `plugins/` | background fetching and source adapters |
| `config.py` / `state.py` | configuration and persistent checklist state |
| `timezones.py` / `text.py` | timezone and terminal-text helpers |

## Scope

Recurring events are expanded for `DAILY`/`WEEKLY`/`MONTHLY` rules with
`INTERVAL`, `COUNT`, `UNTIL`, `BYDAY`, `BYMONTHDAY`, `EXDATE`, `RDATE`, and
`RECURRENCE-ID` overrides. A rule using parts beyond those (`BYSETPOS`,
`BYWEEKNO`, …) collapses to its single start date rather than inventing a
plausible-but-wrong series.
