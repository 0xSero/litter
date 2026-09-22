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

- **meson** + **ninja** — required by native dependencies that build from
  source. Every iOS/Mac CI lane installs these together with `llvm` and `lld`:

  ```bash
  brew install meson ninja llvm lld
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

   If the second command prints nothing, install Codex in a standard tool directory or expose it in the SSH
   session PATH. Background setup does not execute shell startup files: those
   can open desktop windows or block on interactive prompts. User-local
   `.local/bin`, Cargo, Bun, Node managers, Homebrew and Nix paths are
   discovered directly.

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

## Reclaim Build Output

The repository directory is dominated by gitignored build output, not source. Measured
2026-09-22 on the primary development machine, the whole checkout was 73 GB while
the tracked working tree was 36 MB, excluding the 151 MB of submodule checkouts:

| Path | Size | What it is |
|---|---|---|
| `shared/rust-bridge/target/` | 61 GB | Cargo output for every target and profile, 28 GB of it `incremental` |
| `apps/ios/GeneratedRust/` | 5.2 GB | Raw device and simulator staticlibs |
| `apps/android/` | 4.2 GB | Gradle caches and build directories |
| `artifacts/` | 1.8 GB | Test artifacts, `.xcresult` bundles, store snapshots |

None of it is source, and all of it is gitignored. Reclaim it per lane, cheapest
first:

```bash
make prune-dev-cache       # drops Cargo `incremental` dirs only; next build stays incremental-free but reuses `deps`
make prune-ios-sim-only    # drops the device/macabi iOS staticlibs the active simulator lane cannot use
rm -rf artifacts/*         # test artifacts and store snapshots; every one is regenerated on demand
make clean-android         # Gradle build dirs and copied JNI libs
make clean                 # everything, including the stamp cache; costs a full Rust rebuild
```

Keep `artifacts/mobile-triage/triage-state.json` if you still need the triage
ledger; everything else under `artifacts/` is disposable. `make clean-rust`
respects a shared `RUST_TARGET` and leaves it in place rather than deleting a
cache other worktrees are using.

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

Prerequisites: Node 24 (for Material3 theme generation), Java 17 or newer,
Android SDK + build tools for API 36, and the checked-in Gradle 9 wrapper. The Rust/JNI lane also requires the Android NDK
and `cargo-ndk`.

```bash
make material-schemes                  # generate theme sources before standalone Gradle/Android Studio builds
open -a "Android Studio" apps/android  # open in Android Studio
make test-android                      # generate bindings and run unit tests
make android                           # full Rust/JNI + debug APK pipeline
make android-emulator-fast             # host emulator ABI only
```

## Measure Interaction Latency

Three interactions decide whether the app feels fast, and each has a different
measurement path. Nothing here runs in Release: every marker is debug-only, so a
Release build pays nothing for them.

| Interaction | Start marker | End marker |
|---|---|---|
| Tap a session → conversation visible | `PerfTracker.beginInterval("OpenThread", key:)` in `HomeNavigationView.openConversation` (iOS) / `PerfTrace.beginInterval` in `LitterApp.navigateToConversation` (Android) | first `onAppear` of `ConversationView` (iOS) / first `LaunchedEffect` of `ConversationScreen` (Android) |
| Send a message → first streamed token | `PerfTracker.beginInterval("SendMessage", key:)` in `AppModel.startTurn` | first `assistantText` `threadStreamingDelta` (iOS `handleStoreUpdate`, Android `handleUpdate`) |
| Turn finish | — | `PerfTracker.endInterval("SendMessage", key:)` on `threadMetadataChanged`, which closes a turn that streamed no text |

Both platforms write the same shape, so one parser reads both:

```
[LLog][INFO][perf] SendMessage latency key=srv/thr 1432.55ms   # iOS
perf: SendMessage latency key=srv/thr 1432.55ms                  # Android
```

Server-side cost is already timed in Rust and needs no platform change:
`codex-mobile-client` emits `mobile request timing` with `operation` and
`elapsed_ms` per request, and `AppModel.startTurn` logs the `turn/start`
round-trip as `startTurn completed in <ms>ms`.

```bash
make measure-latency             # parse the newest simulator/device logs
make measure-latency-ios-log     # parse a saved simulator console log only
make measure-latency-android     # frame stats, cold start, and perf logcat lines
make measure-latency-ios-tests   # build + run the XCTest latency suites
./tools/scripts/measure-interaction-latency.sh ios-trace <profile.trace>  # signpost intervals
```

Reports land in `artifacts/interaction-latency/<timestamp>/`. `ios-trace` exports
the `os-signpost` table and pairs `begin`/`end` by signpost id, which is the only
way to get frame-accurate tap→render numbers; a simulator console log gives the
same intervals as log lines without the trace overhead.

Two existing baselines are worth knowing before optimizing:

- `InteractionTimingTests` and `PerformanceMeasurementTests` measure the transcript
  pipeline in isolation (`make measure-latency-ios-tests`). They do **not** measure
  a tap or a send: they time `TranscriptTurn.build`, the projection, and the
  streaming render cache at scale.
- `testStreamingRenderCachePerformance_1000Tokens` streams a single growing
  paragraph in 1000 appends. It measured 3.56s before the append fast path
  described below, 0.42s once the fast path existed, and 0.025s once the fast path
  stopped re-walking the whole chunk to hash and measure it. That is the number to
  attack first for "sending the next message feels slow", and it is also the
  regression gate for the fast path.

### Streaming render cost

Both platforms keep a per-item cache of the segments already rendered and re-parse only
a tail, so a tick is not quadratic. The tail is still re-parsed in full whenever the
anchor cannot advance, which for a single growing paragraph is the whole message: the
measured 3.56ms/token came from re-running the Rust block builder,
`splitMarkdownBlocks`, the tail copy, and several `String.count` grapheme walks over
the entire message on every token.

Both caches now fold a plain-text append into the cached final chunk instead, which is
O(appended). `StreamingAssistantRenderCache.extendEntry` (iOS) and
`StreamingTextCoordinator.extendFrontier` (Android) take that path only when the
append cannot change segmentation, and re-parse otherwise:

- the text is a pure append — the cached text is still a prefix, checked by the
  sampled signature plus a bounded comparison at the splice point;
- the final segment is a markdown chunk, not a code fence or an image, and its last
  line is not still only marker characters, which could still become a thematic break,
  an ordered-list marker, or a fence opener;
- the message contains no `http://` or `https://`, since `linkify_bare_web_urls`
  rewrites the block text and cannot be reproduced by appending;
- the appended bytes are ASCII and contain none of ``\n \r | ` ~ $ \ : /``, each of
  which can move a markdown block boundary.

The chunk's identity and length are carried forward too. Recomputing either means
walking the whole chunk again, which cost another 17x on top of the fold itself, so
the extended chunk gets an incremental FNV-1a hash and an incremental length
instead of a fresh `Hasher` and `String.count`.

Anything else falls back to the previous re-parse, so the path is a pure speedup.
`StreamingAssistantRenderCacheTests.testAppendOnlyStreamMatchesColdParse` and
`testStructuralAppendsMatchColdParse` assert that a streamed message renders exactly
what a cold parse of the same text renders.

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
