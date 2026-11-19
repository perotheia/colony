import os
import sys
import tempfile
from pathlib import Path

# colony_api's module singletons read these at import: a scratch journal + a key, before the import.
_TMP = tempfile.mkdtemp(prefix="colony-test-")
os.environ.setdefault("COLONY_JOURNAL", str(Path(_TMP) / "journal.jsonl"))
os.environ.setdefault("COLONY_API_KEY", "test-key")
os.environ.setdefault("COLONY_REGISTRY", str(Path(_TMP) / "registry"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "api"))
