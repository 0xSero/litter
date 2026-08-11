# Android Quickstart

## Prerequisites

- Android SDK (API 36 + build-tools 36.0.0)
- Java 17 or newer; use the checked-in Gradle 9 wrapper
- Rust toolchain and Zig 0.15.x
- Android NDK (`ANDROID_NDK_HOME` or `ANDROID_NDK_ROOT`)
- `cargo-ndk` (`cargo install cargo-ndk`)

## Build Steps

1. Full mobile pipeline (bindings, Rust/JNI, app):

   - `make android`

2. Emulator development lane (host emulator ABI only):

   - `make android-emulator-fast`

3. Android unit tests:

   - `make test-android`

## Modules

- `:app`
- `:core:bridge`

The app consumes UniFFI Kotlin sources directly from
`shared/rust-bridge/generated/kotlin/`; generated bindings are not copied into
an Android source tree.
