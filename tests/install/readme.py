#!/usr/bin/env python3
"""Tripwire for missing or drifted README install commands, using their source.

Checks the literal short-URL commands in this README, not arbitrary prose or
shell equivalence. Windows CI executes the Windows source string itself.
"""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
commands = json.loads((root / "install-commands.json").read_text(encoding="utf-8"))
if set(commands) != {"posix", "windows"}:
    sys.exit("install-commands.json must define both posix and windows")
readme = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "README.md"
text = readme.read_text(encoding="utf-8")
for name, command in commands.items():
    if text.count("\n" + command + "\n") != 1:
        sys.exit(f"README must show the canonical {name} command exactly once")
for line in text.splitlines():
    if any(url in line for url in ("https://cerebe.ai/install.sh", "https://cerebe.ai/install.ps1")):
        if line not in commands.values():
            sys.exit("README installer command differs from install-commands.json")
print("PASS README shows both canonical install commands")
