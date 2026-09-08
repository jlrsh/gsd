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

## Running it

Python 3.11+. `uv run` installs the declared Beautiful Soup dependency used by
the bundled Gradescope plugin automatically.

```sh
uv run gsd.py
```

For direct Python invocation, install `beautifulsoup4` first and run
`python3 gsd.py`.

Add a feed (find the "Calendar Feed" / "Subscribe" URL in your LMS):

```sh
uv run gsd.py --add-feed "https://…/user_abc123.ics" --name Canvas
```

Local `.ics` paths work too, and `webcal://` URLs are rewritten automatically.

Enable Gradescope and save its password in the macOS Login Keychain:

```sh
uv run gsd.py --gradescope-login you@example.edu
```

The email goes in GSD's config; the password does not. GSD tries its private
cookie jar first and only reads the password from Keychain when the session
needs renewing. On a non-macOS machine, set `GSD_GRADESCOPE_PASSWORD` instead.
For SSO, MFA, or bot-check accounts, export browser cookies in Netscape format
and run:

```sh
uv run gsd.py --gradescope-import-cookies ~/Downloads/cookies.txt
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
`uv run gsd.py --edit-config`, to open the complete config in `$VISUAL` or
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
uv run gsd.py --list       # plain text, also used automatically when piped
uv run gsd.py --no-fetch   # cached feeds only, never touch the network
uv run gsd.py --edit-config
uv run gsd.py --timezone America/Indiana/Indianapolis
uv run gsd.py --timezone auto
uv run gsd.py --gradescope-logout
```

## Tests

```sh
uv run --with pytest --with beautifulsoup4 python -m pytest tests/ -q
```

## Scope

Recurring events are expanded for `DAILY`/`WEEKLY`/`MONTHLY` rules with
`INTERVAL`, `COUNT`, `UNTIL`, `BYDAY`, `BYMONTHDAY`, `EXDATE`, `RDATE`, and
`RECURRENCE-ID` overrides. A rule using parts beyond those (`BYSETPOS`,
`BYWEEKNO`, …) collapses to its single start date rather than inventing a
plausible-but-wrong series.
