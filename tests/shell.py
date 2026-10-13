"""Shared helpers for tests that run shell scripts.

BASH is the interpreter every shell test must use:

- Windows: subprocess resolves a bare "bash" through CreateProcess, which searches
  System32 (where bash.exe launches WSL) before PATH. shutil.which follows PATH, so
  CI's Git Bash runs the scripts, as it does for Claude Code hooks.
- macOS: /bin/bash is Bash 3.2, the one a Mac without Homebrew has. CI runners also
  put a newer bash first on PATH, which would hide Bash 4+ features in the scripts.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

if sys.platform == "darwin" and Path("/bin/bash").exists():
    BASH = "/bin/bash"
else:
    BASH = shutil.which("bash") or "bash"
