"""ICS parsing, recurrence, link, and timezone tests."""

from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import gsd

FIXTURES = Path(__file__).parent / "fixtures"


def parse_fixture(name, feed_name="test", horizon=120):
    feed = gsd.Feed(url=f"https://example.test/{name}.ics", name=feed_name)
    text = gsd.decode_ics((FIXTURES / f"{name}.ics").read_bytes())
    return gsd.items_from_ics(text, feed, horizon)


def by_title(items, needle):
    return [i for i in items if needle in i.title]


# -- unfolding and decoding -------------------------------------------------


def test_unfolds_before_decoding_multibyte_split_across_a_fold():
    # RFC 5545 folds on octets, so a UTF-8 char can straddle the boundary.
    raw = b"BEGIN:VCALENDAR\r\nSUMMARY:caf\xc3\r\n \xa9 Meeting\r\nEND:VCALENDAR\r\n"
    with pytest.raises(UnicodeDecodeError):
        raw.decode("utf-8")
    assert "café Meeting" in gsd.decode_ics(raw)


def test_decode_strips_bom_so_begin_vcalendar_matches():
    raw = "﻿BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".encode("utf-8")
    assert gsd.decode_ics(raw).startswith("BEGIN:VCALENDAR")
    assert gsd.looks_like_calendar(gsd.decode_ics(raw))


def test_login_page_is_not_mistaken_for_a_calendar():
    assert not gsd.looks_like_calendar("<!DOCTYPE html><html>Sign in</html>")
    assert not gsd.looks_like_calendar("nothing useful here")


def test_tab_continuation_also_unfolds():
    assert "ABCD" in "".join(gsd.unfold("SUMMARY:AB\r\n\tCD"))


# -- content lines ----------------------------------------------------------


def test_colon_inside_a_quoted_parameter_does_not_split_the_line():
    name, params, value = gsd.split_line(
        'ATTENDEE;CN="Doe, John: TA";ROLE=REQ:mailto:jd@x.edu'
    )
    assert name == "ATTENDEE"
    assert params["CN"] == "Doe, John: TA"
    assert value == "mailto:jd@x.edu"


def test_escaped_text_is_unescaped():
    assert gsd.unescape(r"Reading\, ch. 4-5") == "Reading, ch. 4-5"
    assert gsd.unescape(r"a\nb") == "a\nb"
    assert gsd.unescape(r"a\\nb") == "a\\nb"  # literal backslash, not newline


def test_clean_text_strips_controls_that_would_break_curses():
    assert gsd.clean_text("a\x00b\tc\nd") == "ab c d"


# -- timezones --------------------------------------------------------------


@pytest.mark.parametrize(
    "tzid",
    [
        "America/Indiana/Indianapolis",
        "US/Eastern",
        "Etc/GMT+5",
    ],
)
def test_real_tzids_resolve(tzid):
    assert gsd.tz_for(tzid) is not gsd.LOCAL or tzid == str(gsd.LOCAL)


def test_windows_tzid_maps_instead_of_raising():
    assert str(gsd.tz_for("Eastern Standard Time")) == "America/New_York"
    assert str(gsd.tz_for("W. Europe Standard Time")) == "Europe/Berlin"


def test_mozilla_prefixed_tzid_is_stripped():
    assert (
        str(gsd.tz_for("/mozilla.org/20070129_1/America/New_York"))
        == "America/New_York"
    )


def test_unknown_tzid_falls_back_to_local_rather_than_raising():
    assert gsd.tz_for("Middle Earth Standard Time") is gsd.LOCAL


def test_system_timezone_detection_prefers_iana_tz_environment(monkeypatch):
    monkeypatch.setenv("TZ", "America/New_York")
    assert gsd.detect_local_timezone() == "America/New_York"


def test_selected_local_timezone_observes_dst_after_november_boundary():
    previous = gsd.LOCAL_TIMEZONE
    try:
        gsd.select_local_timezone("America/Indiana/Indianapolis")
        utc_due = datetime(2026, 11, 3, 4, 59, 59, tzinfo=timezone.utc)
        local = utc_due.astimezone(gsd.LOCAL)
        assert local.date() == date(2026, 11, 2)
        assert (local.hour, local.minute) == (23, 59)
        assert local.utcoffset() == timedelta(hours=-5)
    finally:
        gsd.select_local_timezone(previous or "auto")


def test_invalid_selected_timezone_is_rejected():
    with pytest.raises(ValueError, match="unknown IANA timezone"):
        gsd.select_local_timezone("Middle Earth/Minas Tirith")


# -- datetimes --------------------------------------------------------------


def test_date_value_is_all_day():
    dt, all_day = gsd.parse_dt("20260905", {"VALUE": "DATE"})
    assert all_day and dt.date() == date(2026, 9, 5)


def test_utc_suffix_and_tzid_are_both_aware():
    utc, _ = gsd.parse_dt("20260903T035900Z", {})
    assert utc.tzinfo == timezone.utc
    local, _ = gsd.parse_dt("20260901T103000", {"TZID": "America/New_York"})
    assert local.utcoffset() is not None


# -- feed contents ----------------------------------------------------------


def test_canvas_assignment_link_survives_double_encoding():
    items = parse_fixture("canvas")
    hw3 = by_title(items, "HW3")[0]
    assert hw3.link.endswith("module_item_id=55&x=1")
    assert "&amp;" not in hw3.link


def test_escaped_comma_in_summary():
    items = parse_fixture("canvas")
    assert by_title(items, "Reading, ch. 4-5")


def test_valarm_description_does_not_leak_into_the_event():
    items = parse_fixture("canvas")
    reading = by_title(items, "Reading, ch. 4-5")[0]
    assert reading.link is None, "picked up the VALARM's URL"


def test_cancelled_events_are_dropped():
    assert not by_title(parse_fixture("canvas"), "Cancelled thing")


def test_vtimezone_rrule_never_becomes_an_item():
    # The VTIMEZONE DAYLIGHT block carries FREQ=YEARLY;BYDAY=2SU.
    items = parse_fixture("brightspace")
    assert all(i.title != "(untitled)" for i in items)


def test_weekly_rrule_expands_and_honours_exdate():
    items = parse_fixture("brightspace")
    days = {i.day for i in by_title(items, "ME 597 Lecture")}
    assert date(2026, 9, 2) in days  # Wednesday
    assert date(2026, 9, 7) not in days  # EXDATE'd Monday
    assert max(days) <= date(2026, 12, 11)  # UNTIL respected


def test_recurrence_id_override_replaces_that_instance_and_inherits_the_link():
    moved = by_title(parse_fixture("brightspace"), "moved to Friday")
    assert len(moved) == 1
    assert moved[0].link == "https://purdue.brightspace.com/d2l/le/content/1234"


def test_vtodo_uses_due_and_undated_vtodo_survives():
    items = parse_fixture("brightspace")
    due = by_title(items, "Lab notebook check")[0]
    assert due.local_due.date() == date(2026, 9, 10)
    undated = by_title(items, "Pick a project topic")[0]
    assert undated.due is None and undated.day is None


def test_same_event_from_two_feeds_collapses_to_one_key():
    a = parse_fixture("canvas", feed_name="A")
    b = parse_fixture("canvas", feed_name="B")
    assert {i.key for i in a} == {i.key for i in b}


def test_recurring_instances_get_distinct_keys():
    lectures = by_title(parse_fixture("brightspace"), "ME 597 Lecture")
    assert len({i.key for i in lectures}) == len(lectures)


# -- link extraction --------------------------------------------------------


@pytest.mark.parametrize(
    "prop,expected",
    [
        ("URL:https://a.test/x", "https://a.test/x"),
        ("DESCRIPTION:see https://b.test/y for details", "https://b.test/y"),
        ("LOCATION:https://zoom.test/j/123", "https://zoom.test/j/123"),
    ],
)
def test_link_is_found_in_each_property(prop, expected):
    doc = (
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\n"
        "DTSTART:20260903T120000Z\r\nSUMMARY:x\r\n"
        f"{prop}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    feed = gsd.Feed(url="u", name="n")
    assert gsd.items_from_ics(doc, feed, 120)[0].link == expected


def test_trailing_punctuation_is_stripped_from_a_link():
    doc = (
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\n"
        "DTSTART:20260903T120000Z\r\nSUMMARY:x\r\n"
        "DESCRIPTION:go to https://a.test/x. Thanks\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    feed = gsd.Feed(url="u", name="n")
    assert gsd.items_from_ics(doc, feed, 120)[0].link == "https://a.test/x"


# -- recurrence rules -------------------------------------------------------


def _start(days_ago=0):
    return datetime.now(gsd.LOCAL).replace(
        hour=9, minute=0, second=0, microsecond=0
    ) - timedelta(days=days_ago)


def test_unbounded_rule_is_capped_by_the_horizon():
    start = _start()
    lo, hi = start - timedelta(days=1), start + timedelta(days=60)
    out = gsd.expand_rrule(start, {"FREQ": "DAILY"}, lo, hi)
    assert out and max(out) <= hi
    assert len(out) <= 500


def test_count_is_tallied_from_dtstart_not_from_the_window():
    start = _start(days_ago=100)
    lo, hi = start + timedelta(days=90), start + timedelta(days=400)
    out = gsd.expand_rrule(start, {"FREQ": "WEEKLY", "COUNT": "5"}, lo, hi)
    # All five instances fall before the window opens.
    assert out == []


def test_dtstart_is_always_the_first_instance():
    start = _start()  # whatever weekday today is
    other = "MO" if start.weekday() != 0 else "TU"
    out = gsd.expand_rrule(
        start,
        {"FREQ": "WEEKLY", "BYDAY": other},
        start - timedelta(days=1),
        start + timedelta(days=30),
    )
    assert out[0] == start


def test_unsupported_rule_parts_degrade_to_a_single_occurrence():
    start = _start()
    out = gsd.expand_rrule(
        start,
        {"FREQ": "MONTHLY", "BYSETPOS": "-1", "BYDAY": "FR"},
        start - timedelta(days=1),
        start + timedelta(days=365),
    )
    assert out == [start]


def test_monthly_nth_weekday():
    start = datetime(2026, 9, 21, 9, 0, tzinfo=gsd.LOCAL)  # 3rd Monday of Sept
    out = gsd.expand_rrule(
        start,
        {"FREQ": "MONTHLY", "BYDAY": "3MO"},
        start - timedelta(days=1),
        datetime(2026, 12, 31, tzinfo=gsd.LOCAL),
    )
    assert [d.date() for d in out] == [
        date(2026, 9, 21),
        date(2026, 10, 19),
        date(2026, 11, 16),
        date(2026, 12, 21),
    ]


def test_monthly_bymonthday_skips_impossible_dates():
    start = datetime(2026, 1, 31, 9, 0, tzinfo=gsd.LOCAL)
    out = gsd.expand_rrule(
        start,
        {"FREQ": "MONTHLY", "BYMONTHDAY": "31"},
        start - timedelta(days=1),
        datetime(2026, 5, 1, tzinfo=gsd.LOCAL),
    )
    assert [d.month for d in out] == [1, 3]  # no 31 February or April
