# Run from repository root: worker/.venv/bin/pyinstaller worker/TagTrailWorker.spec
from pathlib import Path
import sys
from PyInstaller.utils.hooks import collect_submodules, collect_data_files, copy_metadata

root = Path(SPECPATH).parent
upstream = root / "vendor" / "GoogleFindMyTools"
sys.path[:0] = [str(root), str(upstream)]
hidden = []
for package in ("worker", "Auth", "ProtoDecoders", "FMDNCrypto", "KeyBackup",
                "NovaApi", "SpotApi", "Cryptodome", "gpsoauth", "http_ece",
                "aiohttp", "httpx", "selenium", "cryptography"):
    hidden.extend(collect_submodules(package, filter=lambda name:
                                    ".tests" not in name and ".SelfTest" not in name))
data = [(str(upstream / "LICENSE"), "vendor/GoogleFindMyTools"),
        (str(upstream / "ProtoDecoders" / "Common.proto"), "vendor/GoogleFindMyTools/ProtoDecoders"),
        (str(upstream / "ProtoDecoders" / "DeviceUpdate.proto"), "vendor/GoogleFindMyTools/ProtoDecoders")]
data += collect_data_files("certifi")
data += copy_metadata("gpsoauth")
data += copy_metadata("urllib3")
a = Analysis([str(root / "worker" / "entrypoint.py")],
             pathex=[str(root), str(upstream)], binaries=[], datas=data,
             hiddenimports=hidden, hookspath=[], runtime_hooks=[],
             excludes=["undetected_chromedriver", "frida"], noarchive=False)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="TagTrailWorker",
          debug=False, bootloader_ignore_signals=False, strip=False, upx=False,
          console=True)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False,
               name="TagTrailWorker")
