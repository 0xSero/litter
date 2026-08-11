# litter

<p align="center">
  <img src="apps/ios/Sources/Litter/Resources/brand_logo.png" alt="litter logo" width="180" />
</p>

<p align="center">
  Native iOS + Android client for <a href="https://github.com/openai/codex">Codex</a> and <a href="https://localstudio.ai">Local Studio</a>. Connect to local or remote servers, manage sessions, and run agentic coding workflows from your phone.
</p>

<p align="center">
  <a href="https://kittylitter.app"><img src="docs/badges/website.svg" alt="kittylitter.app" /></a>
  &nbsp;
  <a href="https://apps.apple.com/us/app/kittylitter/id6759521788"><img src="docs/badges/app-store.svg" alt="App Store" /></a>
  &nbsp;
  <a href="https://kittylitter.app/android-beta"><img src="docs/badges/android-beta.svg" alt="Android Beta" /></a>
</p>

## Screenshots (iOS)

<p align="center">
  <img src="docs/screenshots/01-hero-iphone-1320x2868.webp" alt="Home" width="200" />
  <img src="docs/screenshots/02-remote-iphone-1320x2868.webp" alt="Remote servers" width="200" />
  <img src="docs/screenshots/07-generative-ui-iphone-1320x2868.webp" alt="Generative UI" width="200" />
  <img src="docs/screenshots/05-realtime-voice-iphone-1320x2868.webp" alt="Realtime voice" width="200" />
</p>

## Quick Start

```bash
make ios-device-fast   # fast device build
make ios-sim-fast      # fast simulator build
make android-emulator-fast  # fast Android emulator build
```

### Fresh Checkout Prerequisites

After pairing a **new Apple Watch** with Xcode (Window → Devices and Simulators),
run this once so CLI builds can install LitterWatch on it:

```bash
make watch-register
```

This registers the watch UDID with Apple's developer portal and refreshes the
provisioning profile. Without it, `xcodebuild` succeeds but `devicectl ...
install app` fails with "App could not be installed at this time". The target
is idempotent (stamped per-UDID under `.build-stamps/`), so re-runs are no-ops
until a new watch is paired. Override discovery with `WATCH_UDID=<udid>` if
auto-detection fails.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for prerequisites, full build options, TestFlight/App Store release, and SSH setup.

## Repository Layout

```
apps/ios/                  iOS app (Litter scheme, project.yml is source of truth)
apps/android/              Android app (Compose UI, Gradle build)
shared/rust-bridge/
  codex-mobile-client/     Shared Rust client crate + UniFFI surface (iOS & Android)
  codex-slingshot/         Slingshot HTTP/stream transport
  uniffi-bindgen/          Local binding generator wrapper
shared/third_party/codex/  Upstream Codex submodule
shared/third_party/ghostty Upstream Ghostty submodule for the terminal renderer
patches/codex/             Local patch set applied during builds
tools/scripts/             Cross-platform helper scripts
```

## Architecture

Both platforms share a single Rust core (`codex-mobile-client`) via UniFFI-generated bindings. Platform code (Swift/Kotlin) stays thin: UI, permissions, notifications, and platform APIs only. Session state, streaming, hydration, reconnect, SSH, and auth logic live in Rust.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for ownership boundaries, runtime flows, generated-code rules, and the main maintenance risks.

## Contributing

Litter is under active development and a lot of features are in flight. PRs are welcome but will likely only be merged if they're small and target a specific problem — sweeping refactors and new features tend to collide with work already underway. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening one.

## License

Litter is licensed under the GNU General Public License version 3 with an additional permission under GPLv3 section 7 for Apple App Store and Google Play distribution. See [LICENSE](LICENSE).

## Make Targets

| Target | Description |
|---|---|
| `make ios-device-fast` | Fast device build (raw staticlib) |
| `make ios-sim-fast` | Fast simulator build |
| `make ios` | Full package lane (device + sim + xcframework) |
| `make android-emulator-fast` | Fast Android emulator build |
| `make android` | Full Android pipeline |
| `make rust-check` | Host `cargo check` for shared Rust crates |
| `make rust-test` | Host `cargo test` for shared Rust crates |
| `make bindings` | Regenerate UniFFI Swift + Kotlin bindings |
| `make xcgen` | Regenerate Xcode project from `project.yml` |
| `make watch-register` | Register a newly paired Apple Watch with the developer portal (idempotent) |
| `make clean` | Remove all build artifacts |
