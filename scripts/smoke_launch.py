#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def process_command(pid: int) -> str:
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip()


def launch_check(executable: Path, seconds: float = 4.0) -> None:
    """Launch in demo mode with an isolated home; stop only the owned PID."""
    with tempfile.TemporaryDirectory(prefix="TagTrail launch home ") as home:
        env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
        env.pop("TAGTRAIL_WORKER_PATH", None)
        process = subprocess.Popen(
            [str(executable), "-TagTrail.demoMode", "YES"],
            cwd=home, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"app exited during launch with status {process.returncode}: "
                                       + process.stderr.read().decode(errors="replace"))
                time.sleep(0.25)
            command = process_command(process.pid)
            if str(executable) not in command:
                raise RuntimeError(f"ps did not show launched app PID {process.pid}: {command!r}")
            print(f"PASS app launch ps pid={process.pid}: {command}")
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke_launch.py APP_EXECUTABLE")
    try:
        launch_check(Path(sys.argv[1]).resolve())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL app launch: {error}", file=sys.stderr)
        raise SystemExit(1)
