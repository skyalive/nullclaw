#!/usr/bin/env python3
"""
Migrate message log files from old format (YYYYMMDD_HHMMSS_ffffff.md)
to new format (HHMMSS_ffffff.md) inside date-named subdirectories.

Old: workspace/messages/2026-03-22/20260322_154812_221945.md
New: workspace/messages/2026-03-22/154812_221945.md
"""

import os
import re
from pathlib import Path

workspace = Path.home() / ".nullclaw" / "workspace" / "messages"
pattern = re.compile(r"^(\d{8})_(\d{6})_(\d{6})\.md$")

for date_dir in workspace.iterdir():
    if not date_dir.is_dir():
        continue
    # Verify it's a date directory (YYYY-MM-DD)
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date_dir.name):
        continue

    for old_file in date_dir.iterdir():
        m = pattern.match(old_file.name)
        if not m:
            continue
        ymd, hms, micros = m.groups()
        # Optional: verify ymd matches directory name (without dashes)
        expected_ymd = date_dir.name.replace("-", "")
        if ymd != expected_ymd:
            print(f"Warning: filename date {ymd} doesn't match dir {expected_ymd} — skipping {old_file.name}")
            continue
        new_name = f"{hms}_{micros}.md"
        new_path = date_dir / new_name
        if new_path.exists():
            print(f"Conflict: {new_path} already exists, skipping {old_file.name}")
            continue
        old_file.rename(new_path)
        print(f"Renamed: {old_file.name} -> {new_name}")

print("Done.")
