#!/usr/bin/env python3
import os
from pathlib import Path
import re
import subprocess
import sys


MINIMUM = (14, 0)


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def minimum_versions(output: str) -> list[str]:
    lines = output.splitlines()
    versions = []
    for index, line in enumerate(lines):
        command = line.strip()
        if command == "cmd LC_BUILD_VERSION":
            pattern = re.compile(r"^\s*minos\s+([0-9]+(?:\.[0-9]+){1,2})\s*$")
        elif command == "cmd LC_VERSION_MIN_MACOSX":
            pattern = re.compile(r"^\s*version\s+([0-9]+(?:\.[0-9]+){1,2})\s*$")
        else:
            continue
        for candidate in lines[index + 1:index + 8]:
            match = pattern.match(candidate)
            if match:
                versions.append(match.group(1))
                break
    return versions


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-macos-minimum.py APP_BUNDLE")
    root = Path(sys.argv[1])
    if not root.is_dir():
        raise SystemExit(f"app bundle not found: {root}")
    failures = []
    checked = 0
    for directory, _, filenames in os.walk(root, followlinks=False):
        for filename in filenames:
            path = Path(directory) / filename
            kind = subprocess.run(
                ["file", "-b", str(path)],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
            if "Mach-O" not in kind:
                continue
            output = subprocess.run(
                ["otool", "-l", str(path)],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
            versions = minimum_versions(output)
            if not versions:
                failures.append(f"{path}: no macOS minimum-version load command found")
                continue
            checked += 1
            for value in versions:
                if version_tuple(value) > MINIMUM:
                    failures.append(f"{path}: minimum macOS {value} exceeds 14.0")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)
    if checked == 0:
        raise SystemExit("no Mach-O files found in app bundle")
    print(f"Verified {checked} Mach-O files require no newer than macOS 14.0.")


if __name__ == "__main__":
    main()
