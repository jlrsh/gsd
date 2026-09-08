import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load():
    spec = importlib.util.spec_from_file_location("gsd", ROOT / "gsd.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["gsd"] = module          # dataclasses needs the module registered
    spec.loader.exec_module(module)
    return module


gsd = _load()
