"""Manual dates, layout, and terminal text tests."""

from datetime import date, datetime, timedelta

from conftest import gsd

# -- manual entry -----------------------------------------------------------


def test_relative_and_absolute_dates():
    today = date.today()
    assert gsd.parse_when("")[0].date() == today
    assert gsd.parse_when("today")[0].date() == today
    assert gsd.parse_when("tomorrow")[0].date() == today + timedelta(days=1)
    assert gsd.parse_when("+3")[0].date() == today + timedelta(days=3)
    assert gsd.parse_when("2026-09-12")[0].date() == date(2026, 9, 12)


def test_weekday_name_means_the_next_such_day_never_today():
    today = date.today()
    name = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"][today.weekday()]
    assert gsd.parse_when(name)[0].date() == today + timedelta(days=7)


def test_bare_date_is_all_day_but_a_time_makes_it_timed():
    when, all_day = gsd.parse_when("2026-09-12")
    assert all_day and when.hour == 0
    when, all_day = gsd.parse_when("2026-09-12 5pm")
    assert not all_day and when.hour == 17
    when, all_day = gsd.parse_when("2026-09-12 23:59")
    assert not all_day and (when.hour, when.minute) == (23, 59)


def test_nonsense_is_rejected():
    assert gsd.parse_when("sometime soonish") is None


# -- layout -----------------------------------------------------------------


def _item(title, day, key=None, checked=False):
    due = datetime.combine(day, datetime.min.time(), gsd.LOCAL)
    return gsd.Item(
        key=key or title, title=title, due=due, all_day=True, checked=checked
    )


def test_days_are_separated_by_a_blank_line_and_items_are_one_row_each():
    today = date.today()
    main = [_item("a", today), _item("b", today), _item("c", today + timedelta(days=1))]
    rows, main_start = gsd.build_rows([], main)
    kinds = [r.kind for r in rows[main_start:]]
    assert kinds == ["header", "item", "item", "blank", "header", "item"]


def test_completed_rows_come_first_and_main_start_points_past_them():
    today = date.today()
    rows, main_start = gsd.build_rows(
        [_item("done", today, checked=True)], [_item("todo", today)]
    )
    assert main_start > 0
    assert all(r.item is None or r.item.title == "done" for r in rows[:main_start])
    assert rows[main_start].kind == "header"


def test_completed_tasks_are_ordered_oldest_to_newest():
    today = date.today()
    completed = [
        _item("newer", today, checked=True),
        _item("older", today - timedelta(days=2), checked=True),
    ]
    rows, main_start = gsd.build_rows(completed, [])
    titles = [
        row.item.title
        for row in rows[:main_start]
        if row.kind == "item" and row.item is not None
    ]
    assert titles == ["older", "newer"]


def test_overdue_items_group_above_today():
    today = date.today()
    rows, main_start = gsd.build_rows(
        [], [_item("late", today - timedelta(days=3)), _item("now", today)]
    )
    headers = [r.text for r in rows[main_start:] if r.kind == "header"]
    assert headers[0] == "Overdue"
    assert headers[1].startswith("Today")


def test_undated_items_sort_into_their_own_group_last():
    item = gsd.Item(key="u", title="someday", due=None, all_day=True)
    rows, main_start = gsd.build_rows([], [item, _item("now", date.today())])
    headers = [r.text for r in rows[main_start:] if r.kind == "header"]
    assert headers[-1] == "No date"


# -- text metrics -----------------------------------------------------------


def test_width_accounts_for_wide_and_zero_width_characters():
    assert gsd.dwidth("abc") == 3
    assert gsd.dwidth("日本語") == 6
    assert gsd.dwidth("é") == 1  # combining acute adds nothing


def test_trim_never_exceeds_the_budget():
    for text in ("short", "a much longer title than fits", "日本語のタイトル"):
        for limit in range(1, 20):
            assert gsd.dwidth(gsd.dtrim(text, limit)) <= limit
