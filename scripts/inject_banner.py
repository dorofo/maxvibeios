#!/usr/bin/env python3
"""Inject MaxVibeBanner.dylib into a decrypted MAX.app / IPA (Windows-friendly)."""

from __future__ import annotations

import argparse
import shutil
import sys
import zipfile
from pathlib import Path

try:
    import lief
except ImportError:
    print("Install LIEF first: pip install lief", file=sys.stderr)
    sys.exit(1)


DYLIB_NAME = "MaxVibeBanner.dylib"
BANNER_PNG = "banner_character.png"
LOAD_PATH = "@executable_path/Frameworks/MaxVibeBanner.dylib"


def find_app(payload: Path) -> Path:
    apps = list(payload.glob("*.app"))
    if not apps:
        raise SystemExit(f"No .app under {payload}")
    return apps[0]


def inject_macho(binary_path: Path) -> None:
    binary = lief.parse(str(binary_path))
    if binary is None:
        raise SystemExit(f"LIEF failed to parse {binary_path}")

    already = False
    for lib in binary.libraries:
        name = lib if isinstance(lib, str) else getattr(lib, "name", str(lib))
        if name == LOAD_PATH or name.endswith(DYLIB_NAME):
            already = True
            break

    if already:
        print(f"LC_LOAD_DYLIB already present: {LOAD_PATH}")
    else:
        binary.add_library(LOAD_PATH)
        print(f"Added LC_LOAD_DYLIB {LOAD_PATH}")

    # Write to temp then replace (LIEF may need write path)
    tmp = binary_path.with_suffix(binary_path.suffix + ".tmp")
    binary.write(str(tmp))
    tmp.replace(binary_path)
    print(f"Wrote patched binary: {binary_path}")


def copy_payload_files(app: Path, dylib: Path, png: Path) -> None:
    fw = app / "Frameworks"
    fw.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dylib, fw / DYLIB_NAME)
    shutil.copy2(png, fw / BANNER_PNG)
    # Also copy to .app root as fallback for image lookup
    shutil.copy2(png, app / BANNER_PNG)
    print(f"Copied {DYLIB_NAME} and {BANNER_PNG} into {fw}")


def pack_ipa(payload_parent: Path, out_ipa: Path) -> None:
    payload = payload_parent / "Payload"
    if not payload.is_dir():
        raise SystemExit(f"Missing Payload at {payload}")
    if out_ipa.exists():
        out_ipa.unlink()
    with zipfile.ZipFile(out_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in payload.rglob("*"):
            if path.is_file():
                arc = path.relative_to(payload_parent).as_posix()
                zf.write(path, arcname=arc)
    print(f"Packed IPA: {out_ipa} ({out_ipa.stat().st_size} bytes)")


def main() -> None:
    ap = argparse.ArgumentParser(description="Inject MaxVibe Telegram banner dylib into IPA/app")
    ap.add_argument("--app", type=Path, help="Path to MAX.app")
    ap.add_argument("--payload-dir", type=Path, help="Directory containing Payload/ (e.g. temp)")
    ap.add_argument("--dylib", type=Path, required=True, help="MaxVibeBanner.dylib")
    ap.add_argument("--png", type=Path, help="banner_character.png (default: next to dylib or banner/)")
    ap.add_argument("--out-ipa", type=Path, help="Output IPA path")
    args = ap.parse_args()

    dylib = args.dylib.resolve()
    if not dylib.is_file():
        raise SystemExit(f"dylib not found: {dylib}")

    png = args.png
    if png is None:
        for cand in (dylib.parent / BANNER_PNG, Path(__file__).resolve().parents[1] / "banner" / BANNER_PNG):
            if cand.is_file():
                png = cand
                break
    if png is None or not Path(png).is_file():
        raise SystemExit("banner_character.png not found; pass --png")
    png = Path(png).resolve()

    if args.app:
        app = args.app.resolve()
    elif args.payload_dir:
        app = find_app((args.payload_dir.resolve() / "Payload"))
    else:
        raise SystemExit("Pass --app or --payload-dir")

    if not app.is_dir():
        raise SystemExit(f"app not found: {app}")

    # Executable name from Info.plist or default MAX
    exe_name = "MAX"
    try:
        import plistlib

        with open(app / "Info.plist", "rb") as f:
            info = plistlib.load(f)
        exe_name = info.get("CFBundleExecutable", exe_name)
    except Exception:
        pass

    binary = app / exe_name
    if not binary.is_file():
        raise SystemExit(f"executable not found: {binary}")

    copy_payload_files(app, dylib, png)
    inject_macho(binary)

    if args.out_ipa:
        parent = app.parent.parent  # .../temp/Payload/MAX.app -> temp
        if app.parent.name != "Payload":
            raise SystemExit("Expected .../Payload/*.app for --out-ipa")
        pack_ipa(parent, args.out_ipa.resolve())

    print("Done.")


if __name__ == "__main__":
    main()
