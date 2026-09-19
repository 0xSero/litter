# Android Release Automation

Litter Android and the Kittylitter host daemon ship through separate release
channels. A `v0.x` Kittylitter release does not imply that the Android app was
built, submitted, or approved.

- Install the public app from [Google Play](https://play.google.com/store/apps/details?id=com.sigkitten.litter.android).
- Inspect the [Android Play release runs](https://github.com/0xSero/litter/actions/workflows/android-play-release.yml)
  for source SHA, build result, signed APK/AAB artifacts and upload outcome.
- Use the [Android APK releases](https://github.com/0xSero/litter/actions/workflows/android-apk-release.yml)
  for direct distribution. Match the source SHA and the app's Settings version;
  daemon version numbers are unrelated.
- A failed Play preflight means no new store release. An uploaded bundle or a
  draft is not a public rollout. Check Play Console production state separately.
- Maintainers can set `publish_to_play=false` in the Android Play workflow to
  build signed artifacts for an authorized manual Console upload when API
  publishing is unavailable.
- For crash diagnosis, capture `adb logcat -b crash -d` and include app version,
  device/Android version, source SHA (for local builds), and reproduction steps.
  Review the log for private content before sharing it.

## Validation history

- 2026-02-27: validated tag-triggered GitHub Release pipeline.
- 2026-07-30: built the signed `1.6.0` / `200000254` release candidate with
  compile/target SDK 36 and ARM64-only native packaging. Verified the APK
  signature, AAB signature, and 16 KB zip alignment, then installed that exact
  APK on an API 36 ARM64 emulator. Firebase initialized, the embedded Rust
  library and proot bootstrap loaded, the on-device Codex server completed
  `account/read` and `thread/list`, and the saved Local Studio pairing
  reconnected and hydrated completed remote turns. No Play upload was attempted.
