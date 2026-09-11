"""Shared access to GSD's package modules.

The proxy keeps the older tests concise while resolving attributes dynamically
from their owning module (important for the selectable local timezone).
"""

from gsd import (
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


class ModuleProxy:
    modules = (
        timezones,
        paths,
        models,
        config,
        ical,
        sources,
        state,
        events,
        text,
        ui,
        cli,
    )

    def __init__(self):
        for module in self.modules:
            setattr(self, module.__name__.rsplit(".", 1)[-1], module)

    def __getattr__(self, name):
        for module in self.modules:
            if hasattr(module, name):
                return getattr(module, name)
        raise AttributeError(name)


gsd = ModuleProxy()
