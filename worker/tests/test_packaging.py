"""Opt-in native bundle relocation and deployment-target verification."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
BINARY = os.environ.get("TAGTRAIL_WORKER_BINARY")


@unittest.skipUnless(BINARY, "Set TAGTRAIL_WORKER_BINARY to test a built native bundle")
class PackagingTests(unittest.TestCase):
    def test_relocated_no_python_no_checkout_unicode_and_spaces(self):
        binary = Path(BINARY).resolve()
        destination = ROOT / "worker" / ("relocation 合成 " + str(uuid.uuid4()))
        try:
            shutil.copytree(binary.parent, destination / "TagTrail Worker")
            relocated = destination / "TagTrail Worker" / binary.name
            isolated_cwd = destination / "empty working directory"
            isolated_cwd.mkdir()
            env = dict(os.environ, PATH="", PYTHONPATH="", PYTHONHOME="")
            data = {"protocol_version": 1, "request_id": "relocated",
                    "command": "doctor", "timeout_ms": 45000}
            result = subprocess.run([str(relocated)], cwd=isolated_cwd, env=env,
                                    input=(json.dumps(data) + "\n").encode(),
                                    capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(events[-1]["event"], "result")
            self.assertEqual(events[-1]["payload"]["status"], "ok")
            self.assertEqual(result.stderr, b"")
        finally:
            shutil.rmtree(destination, ignore_errors=True)

    def test_macos14_deployment_target_all_native_artifacts(self):
        if not Path("/usr/bin/otool").exists():
            self.skipTest("Mach-O inspection is macOS-only")
        root = Path(BINARY).resolve().parent
        inspected = 0
        for path in root.rglob("*"):
            if not path.is_file() or not (path.suffix in (".so", ".dylib") or path.name == "TagTrailWorker"):
                continue
            result = subprocess.run(["/usr/bin/otool", "-l", str(path)],
                                    capture_output=True, text=True, timeout=10)
            values = re.findall(r"\bminos\s+(\d+\.\d+(?:\.\d+)?)", result.stdout)
            if not values:
                values = re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)", result.stdout)
            for value in values:
                self.assertLessEqual(tuple(map(int, value.split(".")))[:2], (14, 0), str(path))
                inspected += 1
        self.assertGreater(inspected, 10)


if __name__ == "__main__":
    unittest.main()
