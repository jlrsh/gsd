"""Persistent checklist-state tests."""

from datetime import datetime, timedelta

from conftest import gsd

# -- state ------------------------------------------------------------------


def test_state_round_trips(tmp_path, monkeypatch):
    monkeypatch.setattr(gsd.state, "STATE_PATH", tmp_path / "state.json")
    gsd.save_state({"manual": [], "completed": {"k": {"completed_at": "x"}}})
    assert gsd.load_state()["completed"]["k"]["completed_at"] == "x"


def test_corrupt_state_is_quarantined_not_fatal(tmp_path, monkeypatch):
    path = tmp_path / "state.json"
    path.write_text("{not json")
    monkeypatch.setattr(gsd.state, "STATE_PATH", path)
    assert gsd.load_state()["completed"] == {}
    assert (tmp_path / "state.json.bad").exists()


def test_pruning_drops_old_completions_only():
    now = datetime.now(gsd.LOCAL)
    completed = {
        "fresh": {"completed_at": (now - timedelta(days=2)).isoformat()},
        "stale": {"completed_at": (now - timedelta(days=90)).isoformat()},
        "undated": {},
    }
    kept = gsd.prune_completed(completed, 30)
    assert set(kept) == {"fresh", "undated"}
    assert gsd.prune_completed(completed, 0) == completed
