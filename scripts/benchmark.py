#!/usr/bin/env python3
"""BrainStemX benchmark CLI (see src/benchmark/). Run with: uv run python scripts/benchmark.py --help"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

from benchmark.runner import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
