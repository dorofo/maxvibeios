#!/usr/bin/env python3
"""Inject MaxVibeBanner.dylib into a decrypted MAX.app / IPA (Windows-friendly).

Uses in-place Mach-O load-command insertion (does NOT rewrite the binary with LIEF).
LIEF rebuild shrinks/breaks code-signature entitlements and causes session/keychain loss.
"""

from __future__ import annotations

import argparse
import shutil
import struct
import sys
import zipfile
from pathlib import Path

DYLIB_NAME = "MaxVibeBanner.dylib"
BANNER_PNG = "banner_character.png"
LOAD_PATH = "@executable_path/Frameworks/MaxVibeBanner.dylib"

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_CODE_SIGNATURE = 0x1D


def find_app(payload: Path) -> Path:
    apps = list(payload.glob("*.app"))
    if not apps:
        raise SystemExit(f"No .app under {payload}")
    return apps[0]


def _align8(n: int) -> int:
    return (n + 7) & ~7


def _min_section_offset(data: bytearray, ncmds: int) -> int | None:
    """Lowest non-zero section file offset in any LC_SEGMENT_64 (usually __text)."""
    off = 32
    min_off = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sect = off + 72
            for _s in range(nsects):
                if sect + 52 > len(data):
                    break
                soff = struct.unpack_from("<I", data, sect + 48)[0]
                if soff > 0 and (min_off is None or soff < min_off):
                    min_off = soff
                sect += 80
        off += cmdsize
    return min_off


def inject_macho_inplace(binary_path: Path, load_path: str = LOAD_PATH) -> None:
    data = bytearray(binary_path.read_bytes())
    if len(data) < 32:
        raise SystemExit("binary too small")

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit(f"unsupported macho magic: {hex(magic)} (need arm64 MH_MAGIC_64)")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    header_end = 32 + sizeofcmds

    # Already injected?
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_LOAD_DYLIB and cmdsize >= 24:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            cstr = data[off + name_off : off + cmdsize]
            path = cstr.split(b"\x00", 1)[0].decode("utf-8", "replace")
            if path == load_path or path.endswith(DYLIB_NAME):
                print(f"LC_LOAD_DYLIB already present: {path}")
                return
        off += cmdsize

    path_bytes = load_path.encode("utf-8") + b"\x00"
    # cmd + cmdsize + name_offset + timestamp + current_version + compat_version + path
    cmdsize = _align8(24 + len(path_bytes))
    pad = cmdsize - (24 + len(path_bytes))

    min_sect = _min_section_offset(data, ncmds)
    if min_sect is None:
        raise SystemExit("could not find section offsets for slack check")
    slack = min_sect - header_end
    print(f"header_end={header_end} first_section={min_sect} slack={slack} need={cmdsize}")
    if slack < cmdsize:
        raise SystemExit(
            f"not enough header slack for in-place inject ({slack} < {cmdsize}); "
            "refusing LIEF rewrite (breaks keychain/session)"
        )

    # Ensure slack is zeroed / unused
    # Build command
    name_offset = 24
    cmd = bytearray()
    cmd += struct.pack("<II", LC_LOAD_DYLIB, cmdsize)
    cmd += struct.pack("<IIII", name_offset, 2, 0x10000, 0x10000)  # timestamp=2, versions like insert_dylib
    cmd += path_bytes
    cmd += b"\x00" * pad
    assert len(cmd) == cmdsize

    # Write into slack (must currently be unused padding)
    data[header_end : header_end + cmdsize] = cmd
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)

    binary_path.write_bytes(data)
    print(f"In-place injected LC_LOAD_DYLIB ({cmdsize} bytes): {load_path}")
    print(f"Wrote patched binary (size unchanged): {binary_path} ({len(data)} bytes)")


def restore_executable_from_ipa(app: Path, source_ipa: Path, exe_name: str) -> None:
    """Replace executable with pristine copy from decrypted IPA (keeps Info.plist/icons)."""
    with zipfile.ZipFile(source_ipa, "r") as zf:
        # Find matching executable path
        candidates = [
            n for n in zf.namelist()
            if n.endswith(f".app/{exe_name}") and n.startswith("Payload/")
        ]
        if not candidates:
            raise SystemExit(f"executable {exe_name} not found inside {source_ipa}")
        raw = zf.read(candidates[0])
    dest = app / exe_name
    dest.write_bytes(raw)
    print(f"Restored {exe_name} from {source_ipa.name} ({len(raw)} bytes)")


def copy_payload_files(app: Path, dylib: Path, png: Path) -> None:
    fw = app / "Frameworks"
    fw.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dylib, fw / DYLIB_NAME)
    shutil.copy2(png, fw / BANNER_PNG)
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
                # skip accidental backups
                if path.name.endswith(".bak_pre_banner") or path.name.endswith(".tmp"):
                    continue
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
    ap.add_argument(
        "--restore-from-ipa",
        type=Path,
        help="Restore pristine executable from this decrypted IPA before inject "
             "(recommended after a previous LIEF inject)",
    )
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

    if args.restore_from_ipa:
        restore_executable_from_ipa(app, args.restore_from_ipa.resolve(), exe_name)

    copy_payload_files(app, dylib, png)
    inject_macho_inplace(binary)

    if args.out_ipa:
        parent = app.parent.parent
        if app.parent.name != "Payload":
            raise SystemExit("Expected .../Payload/*.app for --out-ipa")
        pack_ipa(parent, args.out_ipa.resolve())

    print("Done.")


if __name__ == "__main__":
    main()
