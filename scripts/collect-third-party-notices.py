#!/usr/bin/env python3
import importlib.metadata
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: collect-third-party-notices.py VENV_PYTHON OUTPUT_DIRECTORY")
    python, output = Path(sys.argv[1]), Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    licenses = output / "python"
    licenses.mkdir(parents=True, exist_ok=True)
    script = (
        "import importlib.metadata as m\n"
        "for d in sorted(m.distributions(), key=lambda x: (x.metadata.get('Name') or '').lower()):\n"
        " n=d.metadata.get('Name') or 'unknown'; v=d.version\n"
        " l=d.metadata.get('License-Expression') or d.metadata.get('License') or ''\n"
        " c=[x.removeprefix('License :: ').replace(' :: ', ' / ') for x in d.metadata.get_all('Classifier', []) if x.startswith('License :: ')]\n"
        " print(f'{n}=={v} | {l or \"; \".join(c) or \"license metadata unavailable\"}')\n"
    )
    listing = subprocess.run(
        [str(python), "-c", script],
        check=True,
        capture_output=True,
        text=True,
    )
    (output / "python-dependencies.txt").write_text(
        "Installed Python distributions and declared license metadata\n"
        "===========================================================\n"
        + listing.stdout,
        encoding="utf-8",
    )

    metadata_script = (
        "import importlib.metadata as m\n"
        "for d in m.distributions():\n"
        " name=(d.metadata.get('Name') or 'unknown').lower().replace('-', '_')\n"
        " for f in d.files or ():\n"
        "  p=str(f).lower()\n"
        "  if '/licenses/' in p or p.endswith(('/license','/license.txt','/copying','/copying.txt','/notice','/notice.txt')):\n"
        "   print(name+'\\t'+str(d.locate_file(f)))\n"
    )
    files = subprocess.run(
        [str(python), "-c", metadata_script],
        check=True,
        capture_output=True,
        text=True,
    )
    for row in files.stdout.splitlines():
        name, source = row.split("\t", 1)
        path = Path(source)
        if path.is_file():
            target_dir = licenses / name
            target_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target_dir / path.name)


if __name__ == "__main__":
    main()
