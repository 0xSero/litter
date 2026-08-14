# Repository Guidelines

## Project Structure & Module Organization
- `apps/ios/Sources/Litter/` contains the iOS app code.
- `apps/ios/Sources/Litter/Views/` holds SwiftUI screens, `Models/` contains app state/session logic, and `Bridge/` contains JSON-RPC + C FFI bridge code.
- `apps/android/app/src/main/java/com/litter/android/ui/` contains Android Compose shell/screens.
- `apps/android/app/src/main/java/com/litter/android/state/` contains Android app state, server/session manager, SSH, and websocket transport.
- `apps/android/core/bridge/` contains Android UniFFI bootstrap and generated Rust bindings.
- `apps/android/app/src/test/java/` contains Android unit tests.
- `apps/android/docs/qa-matrix.md` tracks Android parity QA coverage.
- `shared/rust-bridge/codex-mobile-client/` is the single shared Rust client library consumed by both iOS and Android. It owns the public UniFFI surface, generated upstream RPC coverage, canonical store/reducer state, hydration, reconnect, SSH, shared runtime logic, and the Android JNI bootstrap (`android_context.rs`). `MobileClient` is the top-level internal Rust facade.
- `shared/rust-bridge/codex-bridge/` was removed; its one load-bearing Android JNI bootstrap (`nativeBridgeInit`) was folded into `codex-mobile-client/src/android_context.rs`.
- `apps/ios/Sources/Litter/Bridge/Rust*.swift` — iOS bridge files mapping Swift to the shared Rust layer.
- `apps/android/core/bridge/.../Rust*.kt` — Android bridge files mapping Kotlin to the shared Rust layer. UniFFI Kotlin sources are generated into `shared/rust-bridge/generated/kotlin/` and consumed directly from there; do not maintain copied binding files under Android source roots.
- `shared/third_party/codex/` is the upstream Codex submodule.
- `apps/ios/GeneratedRust/` contains local generated Rust artifacts for iOS builds: UniFFI headers/modulemap plus raw device/simulator staticlibs. These artifacts are not committed.
- `apps/ios/Frameworks/` contains downloaded/package-lane iOS XCFrameworks (`codex_mobile_client.xcframework` in package builds and `litter_ish.xcframework`). These artifacts are not committed.
- `apps/ios/project.yml` is the source of truth for project generation; regenerate `apps/ios/Litter.xcodeproj` instead of hand-editing project files.

## Architecture
- **iOS root layout:** `ContentView` uses a `ZStack` with a persistent `HeaderView`, main content area, and a `SidebarOverlay` that slides from the left.
- **iOS state management:** `AppStore` (Rust, via UniFFI) is the canonical runtime state owner. `AppModel` is the thin Swift observation shell over Rust snapshots and updates. `AppState` is UI-only state.
- **iOS server flow:** Add Server uses explicit Kittylitter, Local Studio, connected-computer, direct URL, or SSH paths. Nearby Mac pairing has a separate platform-owned `_litter-pair._tcp.` browser. Thread/session/account operations come from generated Rust RPC plus store updates.
- **Android root layout:** `LitterAppShell` is the Compose entry; `DefaultLitterAppState` maps backend state into UI state.
- **Android state/transport:** Android should use the same Rust-owned runtime model as iOS instead of re-implementing shared session/thread/account logic in Kotlin.
- **Android server flow:** Add Server uses explicit Kittylitter, Local Studio, connected-computer, direct URL, or SSH paths. Connection, auth, and thread/account flows go through Rust RPC + store updates; Android does not run background NSD or subnet scans.
- **Message rendering parity:** both platforms support reasoning/system sections, code block rendering, and inline image handling.

### Shared Rust Layer
- `codex-mobile-client` is the single public Rust mobile crate. Keep one generated Swift/Kotlin binding surface; do not split UniFFI across multiple mobile crates again.
- Realtime voice uses libwebrtc (Google WebRTC.framework on iOS via stasel/WebRTC SPM, `io.github.webrtc-sdk:android` on Android). The peer connection runs natively on each platform; AEC/NS/VAD are handled by libwebrtc's audio processing module. The Rust layer only owns signaling, session lifecycle, transcript state, and handoff orchestration.
- `AppStore` is the Rust-owned state surface. It owns snapshots, typed updates, and the small set of truly composite/store-local actions.
- `AppClient` is the public UniFFI client surface for direct server operations and typed results.
- `SshBridge` is the shared Rust SSH utility surface. Keep general network scanning out of Swift/Kotlin; the only Bonjour browse is the iOS-only nearby-Mac pairing service.
- iOS uses UniFFI-generated Swift plus thin bridge helpers; Android uses UniFFI-generated Kotlin plus thin bridge helpers.
- iOS Debug/device links the raw static library in `apps/ios/GeneratedRust/ios-device/libcodex_mobile_client.a`. Package/release lanes may still create `apps/ios/Frameworks/codex_mobile_client.xcframework`, but that is not the default debug/device artifact.

## Feature Placement Rules
- Prefer Rust first. If logic is about session state, thread state, streaming, hydration, approvals, auth/account, reconnect, voice transcript/handoff normalization, or status normalization, it belongs in `shared/rust-bridge/codex-mobile-client/`.
- Keep Swift/Kotlin thin. Platform code should only own UI, platform persistence, platform permissions, audio/session APIs, notifications, ActivityKit/CarPlay/Android services, and render-only projections.
- Do not parse upstream wire-format strings in Swift/Kotlin. If a status, event kind, or payload shape matters to both platforms, expose it as a typed UniFFI enum/record from Rust.
- Do not duplicate merge/reducer/state-machine logic in iOS or Android. Shared reconciliation belongs in Rust reducer/store code.
- If shared Rust needs a direct server operation, expose it on `AppClient` with a mobile-owned request/result shape instead of adding a handwritten wrapper on `AppStore`.
- Keep the public UniFFI surface handwritten and narrow. Put reconciliation policy in handwritten Rust reducer/reconcile code.
- `AppStore` should stay minimal: snapshots, subscriptions, and truly composite/store-local actions only. Direct server operations belong on `AppClient`.
- Prefer authoritative updates. Store state should be populated from upstream events first, then targeted refresh/reconcile when upstream events are insufficient. Do not hand-patch platform state after RPC success.
- New boundary types that cross into Swift/Kotlin should be UniFFI-safe Rust records/enums. Internal Rust-only state can stay richer and non-UniFFI.
- Generated Rust sources must stay local-only. Use `*.generated.rs` filenames and do not commit generated Rust files; regenerate them via `./shared/rust-bridge/generate-bindings.sh`.

## Where To Implement New Work
- Add or change direct server coverage:
  - update `shared/rust-bridge/codex-mobile-client/src/ffi/client.rs`
  - update `shared/rust-bridge/codex-mobile-client/src/mobile_client/` and/or reconciliation code as needed
  - regenerate bindings
- Add canonical runtime state, reducer logic, or reconciliation:
  - `shared/rust-bridge/codex-mobile-client/src/store/`
- Add conversation hydration, typed item shaping, or shared status normalization:
  - `shared/rust-bridge/codex-mobile-client/src/conversation.rs`
  - `shared/rust-bridge/codex-mobile-client/src/conversation_uniffi.rs`
  - `shared/rust-bridge/codex-mobile-client/src/types/` and `src/store/boundary.rs`
- Add voice transcript/handoff/shared realtime normalization:
  - `shared/rust-bridge/codex-mobile-client/src/store/voice.rs`
  - reducer/update boundary types in `store/`
- Add iOS-only behavior:
  - `apps/ios/Sources/Litter/Models/` for controllers/platform services
  - `apps/ios/Sources/Litter/Views/` for SwiftUI
  - keep those files free of shared protocol parsing and shared business rules
- Add Android-only behavior:
  - `apps/android/app/` and `apps/android/core/bridge/`
  - keep those files free of duplicated Rust-owned state/reducer logic

## Drift Guardrails
- Default to mobile parity. When a change affects shared mobile behavior or a user-facing mobile workflow, implement and verify it for both iOS and Android in the same pass unless it is truly platform-specific.
- If a mobile change intentionally ships on only one platform, document the reason in your summary and note the follow-up needed for the other platform.
- Before adding new Swift/Kotlin logic, ask: would Android/iOS both need this behavior? If yes, put it in Rust.
- Before adding a new `String` status field to Swift/Kotlin models, ask: should this be a Rust enum instead? Usually yes.
- Before adding a new `AppStore` method, ask: is this a real composite/store action, or should it live on `AppClient` instead?
- Before adding a new platform cache, ask: is this canonical runtime data that should live in the Rust store instead?
- When in doubt, prefer one shared Rust implementation plus a thin platform projection over two parallel native implementations.
- Do not push `shared/third_party/codex` as part of normal repo work. Keep submodule edits local-only unless the user explicitly asks for a separate submodule commit/push, and do not assume a top-level `git push` captures dirty submodule contents.

## Dependencies
### iOS (SPM via `apps/ios/project.yml`)
- **Hairball** / **HairballUI** — Render Markdown in assistant/system messages with custom theming and streaming support.
### Android (Gradle)
- **Compose Material3** — primary Android UI toolkit.
- **Markwon** — Markdown rendering for assistant/system text.
- **androidx.security:security-crypto** — encrypted credential storage.
### Rust Shared Layer (Cargo)
- **codex-app-server-protocol**, **codex-app-server-client**, **codex-protocol**, **codex-core** — upstream Codex crates.
- **tokio-tungstenite** — async WebSocket transport.
- **russh** — SSH client (shared Rust SSH, replacing platform-native SSH libs).
- **uniffi** — generates Swift/Kotlin bindings from Rust.
- **lru**, **base64**, **regex** — utility crates.

## Fresh Checkout Prerequisites
Before building on a new machine, verify:
1. `xcode-select -p` must print `/Applications/Xcode.app/Contents/Developer`, not `/Library/Developer/CommandLineTools`. Fix with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. The Command Line Tools do not include iOS simulator SDKs.
2. `cargo` and `rustc` must come from **rustup**, not Homebrew's `rust` formula. If `which cargo` points to `/opt/homebrew/bin/cargo` (a Homebrew standalone binary, not a rustup proxy), cross-compilation targets like `aarch64-apple-ios-sim` will fail even if `rustup target list` shows them installed. The Makefile prepends the rustup toolchain bin to PATH automatically, but standalone script runs and CI environments must also ensure the correct resolution. Either `brew uninstall rust` or put `~/.cargo/bin` (or the rustup toolchain bin from `rustup which cargo`) before `/opt/homebrew/bin` in PATH.
3. Build toolchain dependencies must be installed via Homebrew: `brew install xcodegen meson ninja llvm lld` and `brew install zig@0.15`. `xcodegen` is required for Xcode project generation; `meson`/`ninja` are required by the embedded iSH build; and `llvm`/`lld` (not Apple's `/usr/bin/clang`, which lacks `lld`) are required to cross-compile the iSH ARM64 vdso. If `llvm`/`lld` are missing, `tools/scripts/check-ish-vdso.sh` fails the Rust build because litter-ish silently degrades the vdso to an empty stub that makes the app SIGABRT at launch.
4. *(Optional)* `pymobiledevice3` enables `make ios-device-run` over Tailscale when the device is not on the local network. Install with `pipx install pymobiledevice3` (or `uv tool install pymobiledevice3`). Also requires Tailscale on both the Mac and the iOS device.

## Build System
The root `Makefile` is the primary build interface. It orchestrates submodule sync, patching, UniFFI binding generation, Rust cross-compilation, raw staticlib generation, optional xcframework packaging, Xcode project generation, and platform builds — with stamp-file caching in `.build-stamps/` so repeated runs skip completed steps. If `sccache` is installed it is used automatically via `RUSTC_WRAPPER=sccache`.

There are two distinct iOS Rust lanes:
- Fast dev lane: raw staticlib + generated headers in `apps/ios/GeneratedRust/`, used by Debug/device builds (`make rust-ios-device-fast`, `make ios-device-fast`).
- Fast simulator lane: raw simulator staticlib + generated headers in `apps/ios/GeneratedRust/ios-sim`, used by Debug/simulator builds (`make rust-ios-sim-fast`, `make ios-sim-fast`).
- Package lane: device+sim Rust build plus `codex_mobile_client.xcframework` packaging (`make rust-ios-package`, `make ios`, `make ios-device`, `make ios-sim`).

Incremental policy:
- Package targets run with `CARGO_INCREMENTAL=0`.
- Dev targets intentionally unset `CARGO_INCREMENTAL` rather than forcing it on, because this repo’s `sccache` setup rejects explicit incremental compilation.

### Common targets
| Target | Description |
|---|---|
| `make ios` | Full iOS package lane: sync → patch → bindings → Rust/Ghostty (device+sim) → xcframework → Alpine fs → xcgen → simulator build |
| `make alpine-fs` | Download the pinned Alpine fakefs used by the embedded iSH runtime. Bump `ALPINE_FS_VERSION` in `Makefile` to upgrade. |
| `make ios-sim` | Full iOS package lane + simulator build |
| `make ios-sim-fast` | Fast iOS simulator lane using raw simulator staticlib outputs in `GeneratedRust/ios-sim` |
| `make ios-device` | Full iOS package lane + device build |
| `make ios-device-fast` | Fast iOS device lane using raw staticlib outputs in `GeneratedRust/` |
| `make ios-run` | Full iOS build then opens Xcode |
| `make android` | Full Android pipeline: sync → kotlin bindings → rust JNI → gradle assemble |
| `make android-emulator-fast` | Fast Android dev build using the host-appropriate emulator ABI (`arm64-v8a` on Apple Silicon, `x86_64` on Intel) |
| `make android-install` | Build + install remote-only APK to emulator |
| `make all` | Both platforms |
| `make rust-ios` | Alias for the full Rust iOS package lane |
| `make rust-ios-package` | Build/package Rust for iOS (device+sim + xcframework) |
| `make rust-ios-sim-fast` | Build raw Rust simulator staticlib + headers only |
| `make rust-ios-device-fast` | Build raw Rust device staticlib + headers only |
| `make rust-android` | Just the Android JNI `.so` files |
| `make rust-check` | Host `cargo check` for shared Rust crates |
| `make rust-test` | Host `cargo test` for shared Rust crates |
| `make bindings` | Regenerate UniFFI Swift + Kotlin bindings |
| `make xcgen` | Regenerate `Litter.xcodeproj` from `project.yml` |
| `make test` | Run Rust + iOS + Android tests |
| `make testflight` | Full iOS build + TestFlight upload |
| `make play-upload` | Full Android build + Google Play upload |
| `make clean` | Remove all build artifacts + stamp cache |

### Cache invalidation
- `make rebuild-bindings` — force-rebuild UniFFI bindings.
- `make clean-rust` / `make clean-ios` / `make clean-android` — remove platform-specific artifacts.

### Configuration overrides (env vars)
- `IOS_SIM_DEVICE` — fallback simulator name when none is booted (default: `iPhone 17 Pro`)
- `IOS_SIM_DESTINATION` — explicit xcodebuild destination override; local simulator builds otherwise prefer an already-booted iOS simulator
- `XCODE_CONFIG` — Xcode build configuration (default: `Debug`)
- `IOS_SCHEME` — Xcode scheme (default: `Litter`)
- `IOS_DEPLOYMENT_TARGET` — minimum iOS version (default: `18.0`)
- `ANDROID_SDK_ROOT` / `ANDROID_NDK_HOME` / `JAVA_HOME` — required for Android builds in bare shells; typical local values are `$HOME/Library/Android/sdk`, `$HOME/Library/Android/sdk/ndk/<version>`, and `/Applications/Android Studio.app/Contents/jbr/Contents/Home`

### Individual scripts (called by Make, can also be run standalone)
- `./apps/ios/scripts/build-rust.sh` — cross-compile Rust for iOS; in fast mode it emits raw staticlibs + headers to `apps/ios/GeneratedRust/`, and in package mode it also creates `codex_mobile_client.xcframework`
- `./apps/ios/scripts/download-alpine-fs.sh` — fetch the pinned Alpine fakefs into `apps/ios/Resources/alpine-fakefs/`. Reads `ALPINE_FS_VERSION` from env (set by `make alpine-fs`).
- `./apps/ios/scripts/sync-codex.sh` — sync codex submodule + apply patches
- `./apps/ios/scripts/regenerate-project.sh` — regenerate Xcode project via xcodegen; this is the safe path because it removes any accidental nested `apps/ios/Litter.xcodeproj/Litter.xcodeproj` before regenerating
- `./apps/ios/scripts/testflight-upload.sh` — archive, export IPA, upload to TestFlight
- `./shared/rust-bridge/generate-bindings.sh` — generate UniFFI Swift/Kotlin bindings
- `./tools/scripts/build-android-rust.sh` — cross-compile Rust JNI libs for Android via `cargo-ndk`
- `./tools/scripts/testflight-feedback.sh` — fetch TestFlight feedback with optional screenshot download; supports `SINCE` / `UNTIL` env filtering for createdDate windows
- `./tools/scripts/fetch-mobile-store-artifacts.py` — one-shot iOS + Android store triage fetcher; use `--last-hours N` or `--since ... --until ...` to pull TestFlight feedback/crashes/crash logs plus Play reviews/crash issues/reports into one output directory and print a Markdown summary with local artifact links. Reuses `testflight-feedback.sh` for the TestFlight feedback path. Android private testing feedback remains Play Console UI-only and is not available through the public APIs used here.
- `./tools/scripts/triage-mobile-feedback.py` — rerunnable GitHub + TestFlight + Play triage ledger. It wraps `fetch-mobile-store-artifacts.py`, fetches GitHub issues/PRs, stores raw per-run snapshots under `artifacts/mobile-triage/runs/`, and preserves per-item status/notes in `artifacts/mobile-triage/triage-state.json`. Use `mark '<item-id>' --status done --note ...` after an item is handled, or `--status pr-open --note 'Fix PR #...'` when a fix PR has been opened, so later runs do not put the same item back in the unhandled queue.

### Hot Reload (InjectionIII)
- Install: `brew install --cask injectioniii`
- Key views have `@ObserveInjection` + `.enableInjection()` wired up (ContentView, ConversationView, HeaderView, SessionSidebarView, MessageBubbleView).
- Debug builds include `-Xlinker -interposable` in linker flags.
- Run the app in simulator, open InjectionIII pointed at the project directory, then save any Swift file to see changes without relaunching.

## Autonomous Debugging Runbook
- Prefer the fast lanes for local iteration before package/release lanes: `make ios-sim-fast`, `make ios-device-fast`, and `make android-emulator-fast`.
- For repeated store-feedback/crash triage across GitHub, TestFlight, and Play, start with `./tools/scripts/triage-mobile-feedback.py --last-hours 24` (or an explicit `--since` / `--until` window). Review `artifacts/mobile-triage/triage-board.md`, then mark handled rows with `./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status done --note 'fixed in ...'` or `--status pr-open --note 'Fix PR #...'`. Use `fetch-mobile-store-artifacts.py` directly only for one-off raw iOS/Android store snapshots or deeper ASC / Play API debugging.
- For iOS simulator debugging, install the latest built app directly from DerivedData instead of trusting an older installed simulator copy: `xcrun simctl install booted <.../Build/Products/Debug-iphonesimulator/Litter.app>` then `xcrun simctl launch booted com.sigkitten.litter`.
- For Xcode project regeneration, use `make xcgen` or `./apps/ios/scripts/regenerate-project.sh`. Do not run `xcodegen generate --spec project.yml --project Litter.xcodeproj` from inside `apps/ios`; that produces a nested `apps/ios/Litter.xcodeproj/Litter.xcodeproj`.
- For Android emulator debugging, build with `make android-emulator-fast`, install with `adb -e install -r apps/android/app/build/outputs/apk/debug/app-debug.apk`, then launch with `adb -e shell am start -n com.sigkitten.litter.android/com.litter.android.MainActivity`.
- Keep both runtimes available when validating shared Rust changes: boot a simulator with `xcrun simctl boot <device>` or through Simulator.app, and verify an emulator is visible with `adb devices -l`.
- Mobile logs now stay local: use Xcode/device console for iOS, Logcat for Android, and normal Rust `tracing` output instead of a collector or spool directory.

## Coding Style & Naming Conventions
- Swift style follows standard Xcode defaults: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions.
- Kotlin style follows standard Android/Kotlin conventions: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members.
- Theme and font choices are user-selectable. Keep new UI colors and text on
  `LitterTheme` / `LitterFont` tokens; reserve terminal-specific monospaced
  styling for terminal surfaces.
- Keep concurrency boundaries explicit (`actor`, `@MainActor`) and avoid cross-actor mutable state.
- Group iOS files by layer (`Views`, `Models`, `Bridge`) and Android files by module (`app/ui`, `app/state`, `core/*`).
- No repository-local SwiftLint/SwiftFormat config is currently committed; keep formatting consistent with existing files.

## Testing Guidelines
- iOS tests: prefer XCTest under `apps/ios/Tests/LitterTests/` with files named `*Tests.swift`.
- Android tests: place unit tests under `apps/android/app/src/test/java/`.
- iOS test command: `xcodebuild test` using the same project/scheme/destination pattern as build commands.
- Android test command: `cd apps/android && ./gradlew :app:testDebugUnitTest`.
- Keep `apps/android/docs/qa-matrix.md` updated when parity scope changes.

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects with optional scope (example: `bridge: retry initialize handshake`).
- PRs should include: purpose, key changes, verification steps (commands/device), and screenshots for UI changes.
- If project structure changes, include updates to `apps/ios/project.yml` and mention whether project regeneration was run.
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
