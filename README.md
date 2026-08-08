# MaxVibe iOS — Telegram startup banner (injected dylib)

Injects a startup modal (same idea as the Android MaxVibe mod) into the decrypted MAX IPA:

- Fetches `https://dorofo.github.io/max-vibe-assets/config.json`
- Shows character + “MaxVibe в Telegram” + subscribe button → `https://t.me/max_vibe`
- Once per day / first launch; kill-switch when `valid_launcher: false`

## Build dylib (GitHub Actions)

Push to `main` or run **Actions → Build MaxVibeBanner dylib → Run workflow**.

Download the artifact `MaxVibeBanner-dylib` (`MaxVibeBanner.dylib` + `banner_character.png`).

## Inject into IPA (Windows)

```bash
pip install lief
python scripts/inject_banner.py ^
  --payload-dir "C:\path\to\temp" ^
  --dylib MaxVibeBanner.dylib ^
  --png banner_character.png ^
  --out-ipa ru.oneme.app_26.17.3_MaxVibe.ipa
```

`temp` must contain `Payload/MAX.app` (already renamed/icon-patched if desired).

Install the IPA with **TrollStore** (or Sideloadly — it re-signs on install).
