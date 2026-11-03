#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

from smoke_app import smoke_app
from smoke_launch import launch_check


def request(worker: Path, command: str, credential_bundle=None):
    request_id = str(uuid.uuid4())
    payload = {
        "protocol_version": 1,
        "request_id": request_id,
        "command": command,
        "timeout_ms": 45_000,
    }
    if credential_bundle is not None:
        payload["credential_bundle"] = credential_bundle
    result = subprocess.run(
        [str(worker)],
        input=(json.dumps(payload) + "\n").encode(),
        capture_output=True,
        check=False,
        timeout=60,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    if not events or any(
        event.get("protocol_version") != 1
        or event.get("request_id") != request_id
        for event in events
    ):
        raise RuntimeError(f"{command}: worker returned invalid protocol output: {result.stderr.decode(errors='replace')}")
    terminal = [event for event in events if event.get("event") in ("result", "error")]
    if len(terminal) != 1:
        raise RuntimeError(f"{command}: expected one terminal event, got {len(terminal)}")
    return result.returncode, terminal[0]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke-packaged.py APP_BUNDLE")
    source_app = Path(sys.argv[1]).resolve()
    worker_relative = Path("Contents/Resources/worker/tagtrail-worker")
    with tempfile.TemporaryDirectory(prefix="TagTrail packaged smoke ") as directory:
        relocated = Path(directory) / "relocated app with spaces.app"
        shutil.copytree(source_app, relocated, symlinks=True)
        app_executable = relocated / "Contents/MacOS/TagTrail"
        if not app_executable.is_file() or not os.access(app_executable, os.X_OK):
            raise RuntimeError(f"app executable missing or not executable: {app_executable}")
        worker = relocated / worker_relative
        if not worker.is_file() or not os.access(worker, os.X_OK):
            raise RuntimeError(f"bundled worker missing or not executable: {worker}")

        code, terminal = request(worker, "doctor")
        if code != 0 or terminal.get("event") != "result":
            raise RuntimeError(f"worker doctor failed: {terminal}")
        doctor = terminal.get("payload", {})
        if doctor.get("status") != "ok" or doctor.get("protocol_version") != 1:
            raise RuntimeError(f"worker doctor returned unexpected payload: {doctor}")

        code, terminal = request(worker, "authenticate", {})
        if terminal.get("event") != "error" or terminal.get("code") not in (
            "authentication-required",
            "authentication_required",
        ):
            raise RuntimeError(f"empty-credentials check did not require authentication: {terminal}")
        if code == 0:
            raise RuntimeError("worker returned success for empty credentials")
        print(f"PASS relocated worker doctor: {doctor}")
        print("PASS empty credential bundle rejected as authentication-required")
        smoke_app(app_executable)
        launch_check(app_executable)
        print(f"PASS relocated app path with spaces: {relocated}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"FAIL packaged smoke: {error}", file=sys.stderr)
        raise SystemExit(1)
