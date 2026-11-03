#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile


def check_app(executable: Path, command: str, timeout: int) -> None:
    with tempfile.TemporaryDirectory(prefix="TagTrail app smoke ") as directory:
        result = subprocess.run(
            [str(executable), f"--{command}"],
            cwd=directory,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    if result.returncode != 0 or f"PASS TagTrail {command}" not in result.stdout:
        raise RuntimeError(
            f"app {command} failed (exit {result.returncode}):\n"
            + result.stdout + result.stderr
        )
    print(result.stdout.strip())


def smoke_app(executable: Path) -> None:
    check_app(executable, "self-test", 60)
    check_app(executable, "smoke-demo", 100)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke_app.py APP_EXECUTABLE")
    try:
        smoke_app(Path(sys.argv[1]).resolve())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL app smoke: {error}", file=sys.stderr)
        raise SystemExit(1)
