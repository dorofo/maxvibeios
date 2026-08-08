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
pip install lief   # not required for inject anymore
python scripts/inject_banner.py ^
  --payload-dir "C:\path\to\temp" ^
  --dylib MaxVibeBanner.dylib ^
  --png banner_character.png ^
  --restore-from-ipa "ru.oneme.app_26.17.3_decrypted.ipa" ^
  --out-ipa ru.oneme.app_26.17.3_MaxVibe.ipa
```

`--restore-from-ipa` restores a pristine `MAX` binary before inject (important: never use LIEF rewrite — it breaks keychain/session).

Install with **TrollStore**.
