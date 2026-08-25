#!/usr/bin/env python3
"""Inject MaxVibeBanner.dylib into a decrypted MAX.app / IPA (Windows-friendly).

Uses in-place Mach-O load-command insertion (does NOT rewrite the binary with LIEF).
Optionally signs with ldid + entitlements for TrollStore keychain/app-groups.
"""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import zipfile
from pathlib import Path

DYLIB_NAME = "MaxVibeBanner.dylib"
BANNER_PNG = "banner_character.png"
LOAD_PATH = "@executable_path/Frameworks/MaxVibeBanner.dylib"

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C


def find_app(payload: Path) -> Path:
    apps = list(payload.glob("*.app"))
    if not apps:
        raise SystemExit(f"No .app under {payload}")
    return apps[0]


def _align8(n: int) -> int:
    return (n + 7) & ~7


def _min_section_offset(data: bytearray, ncmds: int) -> int | None:
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
        raise SystemExit(f"unsupported macho magic: {hex(magic)}")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    header_end = 32 + sizeofcmds

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
    cmdsize = _align8(24 + len(path_bytes))
    pad = cmdsize - (24 + len(path_bytes))

    min_sect = _min_section_offset(data, ncmds)
    if min_sect is None:
        raise SystemExit("could not find section offsets for slack check")
    slack = min_sect - header_end
    print(f"header_end={header_end} first_section={min_sect} slack={slack} need={cmdsize}")
    if slack < cmdsize:
        raise SystemExit(f"not enough header slack ({slack} < {cmdsize})")

    name_offset = 24
    cmd = bytearray()
    cmd += struct.pack("<II", LC_LOAD_DYLIB, cmdsize)
    cmd += struct.pack("<IIII", name_offset, 2, 0x10000, 0x10000)
    cmd += path_bytes
    cmd += b"\x00" * pad
    assert len(cmd) == cmdsize

    data[header_end : header_end + cmdsize] = cmd
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)
    binary_path.write_bytes(data)
    print(f"In-place injected LC_LOAD_DYLIB ({cmdsize} bytes): {load_path}")


def restore_executable_from_ipa(app: Path, source_ipa: Path, exe_name: str) -> None:
    with zipfile.ZipFile(source_ipa, "r") as zf:
        candidates = [
            n for n in zf.namelist()
            if n.endswith(f".app/{exe_name}") and n.startswith("Payload/")
        ]
        if not candidates:
            raise SystemExit(f"executable {exe_name} not found inside {source_ipa}")
        raw = zf.read(candidates[0])
    (app / exe_name).write_bytes(raw)
    print(f"Restored {exe_name} from {source_ipa.name} ({len(raw)} bytes)")


ALT_ICON_FILES = (
    "AppIconOriginal@2x.png",
    "AppIconOriginal@3x.png",
    "AppIconZivert@2x.png",
    "AppIconZivert@3x.png",
    "AppIconMaxVibe2@2x.png",
    "AppIconMaxVibe2@3x.png",
)

ALT_ICON_KEYS = {
    "MaxOriginal": "AppIconOriginal",
    "MaxZivert": "AppIconZivert",
    "MaxVibe2": "AppIconMaxVibe2",
}


def find_icons_dir(dylib: Path) -> Path | None:
    candidates = (
        dylib.parent / "icons",
        Path(__file__).resolve().parents[1] / "banner" / "icons",
        dylib.parent,
    )
    for cand in candidates:
        if (cand / ALT_ICON_FILES[0]).is_file():
            return cand
    return None


def install_alternate_icons(app: Path, dylib: Path) -> None:
    icons_dir = find_icons_dir(dylib)
    if not icons_dir:
        print("WARNING: alternate icon PNGs not found — skip CFBundleAlternateIcons")
        return

    copied = 0
    for name in ALT_ICON_FILES:
        src = icons_dir / name
        if src.is_file():
            shutil.copy2(src, app / name)
            copied += 1
    print(f"Copied {copied} alternate icon files from {icons_dir}")

    try:
        import plistlib
    except Exception as exc:
        print(f"WARNING: plistlib unavailable ({exc}) — skip Info.plist icon keys")
        return

    plist_path = app / "Info.plist"
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)

    alts = {
        key: {
            "CFBundleIconFiles": [file_stem],
            "UIPrerenderedIcon": True,
        }
        for key, file_stem in ALT_ICON_KEYS.items()
    }
    for icons_key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icons = info.get(icons_key)
        if not isinstance(icons, dict):
            icons = {}
            info[icons_key] = icons
        icons["CFBundleAlternateIcons"] = alts

    with open(plist_path, "wb") as f:
        plistlib.dump(info, f, sort_keys=False)
    print("Info.plist CFBundleAlternateIcons:", ", ".join(ALT_ICON_KEYS))


def copy_payload_files(app: Path, dylib: Path, png: Path) -> None:
    fw = app / "Frameworks"
    fw.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dylib, fw / DYLIB_NAME)
    shutil.copy2(png, fw / BANNER_PNG)
    shutil.copy2(png, app / BANNER_PNG)
    print(f"Copied {DYLIB_NAME} and {BANNER_PNG} into {fw}")
    install_alternate_icons(app, dylib)


def pack_ipa(payload_parent: Path, out_ipa: Path) -> None:
    payload = payload_parent / "Payload"
    if not payload.is_dir():
        raise SystemExit(f"Missing Payload at {payload}")
    if out_ipa.exists():
        out_ipa.unlink()
    with zipfile.ZipFile(out_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in payload.rglob("*"):
            if path.is_file():
                if path.name.endswith(".bak_pre_banner") or path.name.endswith(".tmp"):
                    continue
                arc = path.relative_to(payload_parent).as_posix()
                zf.write(path, arcname=arc)
    print(f"Packed IPA: {out_ipa} ({out_ipa.stat().st_size} bytes)")


def ldid_sign(path: Path, entitlements: Path, ldid: Path | None = None) -> None:
    candidates = []
    if ldid:
        candidates.append(Path(ldid))
    candidates.append(Path(__file__).resolve().parents[1] / "tools" / "ldid.exe")
    which = shutil.which("ldid")
    exe = next((str(c) for c in candidates if c.is_file()), None)
    if not exe and which:
        exe = which
    if not exe:
        print("WARNING: ldid not found — skip entitlements sign")
        return
    cmd = [exe, f"-S{entitlements}", str(path)]
    print("Running:", " ".join(cmd))
    subprocess.check_call(cmd)
    print(f"Signed {path.name} with {entitlements.name}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Inject MaxVibe Telegram banner dylib into IPA/app")
    ap.add_argument("--app", type=Path)
    ap.add_argument("--payload-dir", type=Path)
    ap.add_argument("--dylib", type=Path, required=True)
    ap.add_argument("--png", type=Path)
    ap.add_argument("--out-ipa", type=Path)
    ap.add_argument("--restore-from-ipa", type=Path)
    ap.add_argument("--entitlements", type=Path)
    ap.add_argument("--ldid", type=Path)
    ap.add_argument("--no-sign", action="store_true")
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
        app = find_app(args.payload_dir.resolve() / "Payload")
    else:
        raise SystemExit("Pass --app or --payload-dir")

    exe_name = "MAX"
    try:
        import plistlib
        with open(app / "Info.plist", "rb") as f:
            exe_name = plistlib.load(f).get("CFBundleExecutable", exe_name)
    except Exception:
        pass

    binary = app / exe_name
    if not binary.is_file():
        raise SystemExit(f"executable not found: {binary}")

    if args.restore_from_ipa:
        restore_executable_from_ipa(app, args.restore_from_ipa.resolve(), exe_name)

    copy_payload_files(app, dylib, png)
    inject_macho_inplace(binary)

    ents = args.entitlements
    if ents is None:
        for cand in (
            Path(__file__).resolve().parents[1] / "banner" / "entitlements.plist",
            dylib.parent / "entitlements.plist",
        ):
            if cand.is_file():
                ents = cand
                break
    if not args.no_sign and ents and Path(ents).is_file():
        e = Path(ents).resolve()
        ldid_sign(binary, e, args.ldid)
        ldid_sign(app / "Frameworks" / DYLIB_NAME, e, args.ldid)

    if args.out_ipa:
        parent = app.parent.parent
        if app.parent.name != "Payload":
            raise SystemExit("Expected .../Payload/*.app for --out-ipa")
        pack_ipa(parent, args.out_ipa.resolve())

    print("Done.")


if __name__ == "__main__":
    main()
