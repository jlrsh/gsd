"""Gradescope plugin and source-config integration tests."""

from datetime import datetime

from bs4 import BeautifulSoup
from conftest import gsd

from gsd.plugins import gradescope

DASHBOARD = """
<div class="courseList">
 <div class="courseList--coursesForTerm">
  <a class="courseBox" href="/courses/100001">
   <span class="courseBox--shortname">CS 25100</span>
   <span class="courseBox--name">Data Structures</span>
  </a>
 </div>
 <div class="courseList--coursesForTerm">
  <a class="courseBox" href="/courses/90001">
   <span class="courseBox--shortname">OLD 101</span>
  </a>
 </div>
</div>
"""

ASSIGNMENTS = """
<table id="assignments-student-table"><tbody>
 <tr><th><a href="/courses/100001/assignments/55/submissions/2">Homework 1</a></th>
  <td>18 / 20</td><td>
   <time class="submissionTimeChart--releaseDate" datetime="2026-09-01 08:00:00 -0400">released</time>
   <time class="submissionTimeChart--dueDate" aria-label="Due Sep 7"
         datetime="2026-09-07 23:59:00 -0400">due</time>
   <time aria-label="Late Due" datetime="2026-09-09 23:59:00 -0400">late</time>
  </td></tr>
</tbody></table>
"""


def test_parser_uses_current_term_and_real_due_date():
    courses = gradescope.parse_courses(BeautifulSoup(DASHBOARD, "html.parser"))
    assert [course["id"] for course in courses] == ["100001"]
    rows = gradescope.parse_assignments(
        BeautifulSoup(ASSIGNMENTS, "html.parser"), courses[0]
    )
    assert rows[0]["due_iso"] == "2026-09-07T23:59:00-04:00"
    assert rows[0]["key"] == "a55"
    assert rows[0]["status"] == "18 / 20"
    assert rows[0]["url"].endswith("/courses/100001/assignments/55")


def test_direct_adapter_has_stable_identity_and_no_ics():
    row = {
        "course_id": "100001",
        "key": "a55",
        "course": "CS 25100",
        "title": "Homework 1",
        "due_iso": "2026-09-07T23:59:00-04:00",
        "url": "https://www.gradescope.com/x",
    }
    first = gsd.gradescope_items([row])[0]
    second = gsd.gradescope_items([dict(row)])[0]
    assert first.key == second.key
    assert first.title == "CS 25100 — Homework 1"
    assert first.due == datetime.fromisoformat(row["due_iso"])
    assert first.source == "Gradescope"


def test_plugin_cache_is_private_json(tmp_path):
    path = tmp_path / "plugin" / "assignments.json"
    rows = [{"title": "Homework 1"}]
    gradescope.write_cache(path, rows)
    loaded, timestamp = gradescope.read_cache(path)
    assert loaded == rows and timestamp
    assert path.stat().st_mode & 0o777 == 0o600


def test_config_loads_disabled_feeds_and_gradescope(tmp_path, monkeypatch):
    config = tmp_path / "config.toml"
    config.write_text("""
[settings]
horizon_days = 30
[[feed]]
url = "https://calendar.test/a.ics"
name = "Canvas"
enabled = false
[plugins.gradescope]
enabled = true
email = "student@example.edu"
""")
    monkeypatch.setattr(gsd.config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(gsd.config, "DATA_DIR", tmp_path)
    monkeypatch.setattr(gsd.config, "CACHE_DIR", tmp_path / "cache")
    monkeypatch.setattr(gsd.config, "CONFIG_PATH", config)
    feeds, settings = gsd.load_config()
    assert len(feeds) == 1 and not feeds[0].enabled
    assert settings["gradescope"] == {
        "enabled": True,
        "email": "student@example.edu",
        "all_terms": False,
        "skip_submitted": False,
    }


def test_toggle_preserves_comments_and_other_settings(tmp_path, monkeypatch):
    config = tmp_path / "config.toml"
    config.write_text("""# keep me
[settings]
horizon_days = 42 # also keep me
[[feed]]
url = "https://calendar.test/a.ics"
name = "Canvas"
[plugins.gradescope]
enabled = false # toggle this
email = "student@example.edu"
""")
    monkeypatch.setattr(gsd.config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(gsd.config, "DATA_DIR", tmp_path)
    monkeypatch.setattr(gsd.config, "CACHE_DIR", tmp_path / "cache")
    monkeypatch.setattr(gsd.config, "CONFIG_PATH", config)
    gsd.set_source_enabled("feed", "https://calendar.test/a.ics", False)
    gsd.set_source_enabled("gradescope", gsd.GRADESCOPE_SOURCE, True)
    text = config.read_text()
    assert "# keep me" in text and "horizon_days = 42 # also keep me" in text
    assert "enabled = true # toggle this" in text
    feeds, settings = gsd.load_config()
    assert not feeds[0].enabled and settings["gradescope"]["enabled"]


def test_password_environment_override(monkeypatch):
    monkeypatch.setenv(gradescope.PASSWORD_ENV, "do-not-print-this")
    assert gradescope.password_for("student@example.edu") == "do-not-print-this"


def test_gradescope_sync_state_is_a_separate_right_status():
    class Screen:
        pass

    settings = dict(gsd.DEFAULTS)
    settings["gradescope"] = {"enabled": True, "email": "student@example.edu"}
    app = gsd.App(
        Screen(), [], settings, {"completed": {}, "checked": [], "manual": []}
    )
    status = app.status[gsd.GRADESCOPE_SOURCE]
    status.pending = False
    status.cached_at = __import__("time").time()
    left, right = app.status_line()
    assert left == "0 open"
    assert right == "Gradescope synced just now"


def test_timezone_selection_patches_settings_without_losing_comments(
    tmp_path, monkeypatch
):
    config = tmp_path / "config.toml"
    config.write_text("""# keep this
[settings]
horizon_days = 42
timezone = "auto" # local computer
""")
    monkeypatch.setattr(gsd.config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(gsd.config, "DATA_DIR", tmp_path)
    monkeypatch.setattr(gsd.config, "CACHE_DIR", tmp_path / "cache")
    monkeypatch.setattr(gsd.config, "CONFIG_PATH", config)
    previous = gsd.LOCAL_TIMEZONE
    try:
        resolved = gsd.configure_timezone("America/Indiana/Indianapolis")
        assert resolved == "America/Indiana/Indianapolis"
        text = config.read_text()
        assert "# keep this" in text and "# local computer" in text
        assert 'timezone = "America/Indiana/Indianapolis" # local computer' in text
    finally:
        gsd.select_local_timezone(previous or "auto")
