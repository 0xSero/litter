# Development Guide

## Prerequisites

- **Xcode.app** (full install, not only Command Line Tools):

  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```

- **Rust via rustup** with iOS targets. If Homebrew's `rust` formula is
  installed, its `cargo`/`rustc` will shadow rustup and break
  cross-compilation. Either `brew uninstall rust` or ensure `~/.cargo/bin`
  appears before `/opt/homebrew/bin` in your `PATH`.

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```

- **meson** + **ninja** (required by `webrtc-audio-processing-sys`):

  ```bash
  brew install meson
  ```

- **xcodegen** (for regenerating `Litter.xcodeproj`):

  ```bash
  brew install xcodegen
  ```

- **Zig 0.15.x** (for the pinned Ghostty terminal library). The build resolves
  the exact version declared by the Ghostty submodule. Install the matching
  Homebrew formula when the default `zig` is a different version:

  ```bash
  brew install zig@0.15
  ```

## Connect Your Mac to Litter Over SSH

Use this flow to make Codex sessions from your Mac visible in the iOS/Android
app.

1. Enable SSH on the Mac.

   - UI: `System Settings` -> `General` -> `Sharing` -> enable `Remote Login`.
   - CLI:

     ```bash
     sudo systemsetup -setremotelogin on
     ```

   - If you get a Full Disk Access error, grant it to your terminal app in
     `System Settings` -> `Privacy & Security` -> `Full Disk Access`, then
     restart the terminal and retry.

2. Verify SSH and Codex binaries from a non-interactive SSH shell.

   ```bash
   ssh <mac-user>@<mac-host-or-ip> 'echo ok'
   ssh <mac-user>@<mac-host-or-ip> \
     'command -v codex || command -v codex-app-server'
   ```

   If the second command prints nothing, install Codex and/or fix shell PATH
   startup files.

3. Connect from the Litter app.

   - Keep phone and Mac on the same LAN (or same Tailnet).
   - Open **Add Server** → **SSH or Codex URL**.
   - Paste the explicit `ws://`/`wss://` app-server URL, or choose SSH and
     enter the Mac host and credentials.

4. Fallback: run app-server manually bound to loopback and forward the port
   over SSH.

   On the Mac:

   ```bash
   codex app-server --listen ws://127.0.0.1:8390
   ```

   Then connect the phone via the SSH flow in **Add Server**. Litter opens the SSH
   connection, port-forwards `127.0.0.1:8390`, and connects through the tunnel.
   Do not bind `0.0.0.0` unless you fully understand the exposure; the SSH flow
   is the supported path.

5. Thread/session listing is `cwd`-scoped. If expected sessions are missing,
   choose the same working directory used when those sessions were created.

## Codex Submodule + Patches

Upstream Codex is vendored as a submodule at `shared/third_party/codex`.

Every `patches/codex/*.patch` file is part of the active mobile patch set.
`sync-codex.sh` owns the dependency-sensitive apply order; the Makefile uses
the same directory as its invalidation and unpatch manifest. See
[`patches/codex/README.md`](../patches/codex/README.md) for each patch's intent
and downstream consumer.

Sync/apply (idempotent):

```bash
./apps/ios/scripts/sync-codex.sh
```

Pass `--recorded-gitlink` to reset the submodule to the commit recorded in the
superproject.

## Build the Rust Bridge

```bash
./apps/ios/scripts/build-rust.sh # package mode: device + sim + xcframework
./apps/ios/scripts/build-rust.sh --fast-device # raw device staticlib only
```

## Build and Run iOS

Regenerate project if `apps/ios/project.yml` changed:

```bash
make xcgen
```

Open in Xcode:

```bash
open apps/ios/Litter.xcodeproj
```

CLI build:

```bash
xcodebuild \
  -project apps/ios/Litter.xcodeproj \
  -scheme Litter \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Build and Run Android

Prerequisites: Java 17 or newer, Android SDK + build tools for API 36, and the
checked-in Gradle 9 wrapper. The Rust/JNI lane also requires the Android NDK
and `cargo-ndk`.

```bash
open -a "Android Studio" apps/android  # open in Android Studio
make test-android                      # generate bindings and run unit tests
make android                           # full Rust/JNI + debug APK pipeline
make android-emulator-fast             # host emulator ABI only
```

## TestFlight (iOS)

1. Authenticate with App Store Connect:

   ```bash
   asc auth login \
     --name "Litter ASC" \
     --key-id "<KEY_ID>" \
     --issuer-id "<ISSUER_ID>" \
     --private-key "$HOME/AppStore.p8" \
     --network
   ```

2. Bootstrap TestFlight defaults:

   ```bash
   APP_BUNDLE_ID=<BUNDLE_ID> ./apps/ios/scripts/testflight-setup.sh
   ```

3. Build and upload:

   ```bash
   APP_BUNDLE_ID=<BUNDLE_ID> \
   APP_STORE_APP_ID=<APP_STORE_CONNECT_APP_ID> \
   TEAM_ID=<APPLE_TEAM_ID> \
   ASC_KEY_ID=<KEY_ID> \
   ASC_ISSUER_ID=<ISSUER_ID> \
   ASC_PRIVATE_KEY_PATH="$HOME/AppStore.p8" \
   ./apps/ios/scripts/testflight-upload.sh
   ```

   - Reads `MARKETING_VERSION` from `apps/ios/project.yml`; auto-bumps the patch
     version if it is already live.
   - Auto-increments build number from the latest App Store Connect build.

## App Store Release (iOS)

```bash
APP_BUNDLE_ID=<BUNDLE_ID> \
APP_STORE_APP_ID=<APP_STORE_CONNECT_APP_ID> \
TEAM_ID=<APPLE_TEAM_ID> \
ASC_KEY_ID=<KEY_ID> \
ASC_ISSUER_ID=<ISSUER_ID> \
ASC_PRIVATE_KEY_PATH="$HOME/AppStore.p8" \
./apps/ios/scripts/app-store-release.sh
```

Metadata is sourced from `apps/ios/fastlane/metadata/en-US/`.
