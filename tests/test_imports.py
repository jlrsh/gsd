"""Package-boundary smoke tests."""


def test_all_application_modules_import_without_cycles():
    from gsd import (  # noqa: F401
        cli,
        config,
        events,
        ical,
        models,
        paths,
        sources,
        state,
        text,
        timezones,
        ui,
    )
