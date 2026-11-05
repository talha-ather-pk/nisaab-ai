"""Vercel entry point: the whole FastAPI app as one Python serverless function (see vercel.json)."""

import sys
from pathlib import Path

# The backend modules import each other by top-level name (`from config import ...`).
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from main import app  # noqa: E402,F401  (Vercel serves the ASGI `app`)
