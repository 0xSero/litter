# Android Release Automation

This doc tracks Android release automation validation runs.

- 2026-02-27: validated tag-triggered GitHub Release pipeline.
- 2026-07-30: built the signed `1.6.0` / `200000254` release candidate with
  compile/target SDK 36 and ARM64-only native packaging. Verified the APK
  signature, AAB signature, and 16 KB zip alignment, then installed that exact
  APK on an API 36 ARM64 emulator. Firebase initialized, the embedded Rust
  library and proot bootstrap loaded, the on-device Codex server completed
  `account/read` and `thread/list`, and the saved Local Studio pairing
  reconnected and hydrated completed remote turns. No Play upload was attempted.
