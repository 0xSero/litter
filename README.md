# litter

![litter logo](https://raw.githubusercontent.com/dnakov/litter/main/apps/ios/Sources/Litter/Resources/brand_logo.png)

Native iOS + Android client for running agentic coding workflows from your phone. Connects to the [alleycat](https://github.com/dnakov/alleycat) daemon (distributed as `kittylitter`) running on your machine, which bridges multiple coding agents over a single QUIC connection via Iroh.

## Supported Agents

| Agent | Description |
|---|---|
| **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** | Anthropic's CLI coding agent |
| **[Codex](https://github.com/openai/codex)** | OpenAI's CLI coding agent |
| **[OpenCode](https://opencode.ai)** | Open-source coding assistant |
| **[Pi](https://pi.monicahq.com)** | AI coding agent by Monica |
| **[Factory Droid](https://factory.ai)** | Factory's AI coding agent |

## Install

- **iOS**: [App Store](https://apps.apple.com/app/litter/id6743473375)
- **Android**: [Google Play](https://play.google.com/store/apps/details?id=com.sigkitten.litter.android)

## Quick Start

### 1. Install the daemon on your computer

```bash
npm install -g kittylitter
```

Or from source via the [alleycat repo](https://github.com/dnakov/alleycat).

### 2. Install your preferred coding agent(s)

```bash
# Claude Code
npm install -g @anthropic-ai/claude-code && claude /login

# Codex — see https://github.com/openai/codex

# OpenCode — see https://opencode.ai
```

### 3. Start and pair

```bash
kittylitter install   # autostart at login (no admin needed)
kittylitter pair --qr # scan with the Litter app
```

The daemon spawns agents on demand — install whichever ones you'll use. See the [alleycat README](https://github.com/dnakov/alleycat#what-the-daemon-spawns) for per-agent details.

## Screenshots (iOS)

![Home](https://raw.githubusercontent.com/dnakov/litter/main/docs/screenshots/01-hero-iphone-1320x2868.png)
![Remote servers](https://raw.githubusercontent.com/dnakov/litter/main/docs/screenshots/02-remote-iphone-1320x2868.png)
![Generative UI](https://raw.githubusercontent.com/dnakov/litter/main/docs/screenshots/07-generative-ui-iphone-1320x2868.png)
![Realtime voice](https://raw.githubusercontent.com/dnakov/litter/main/docs/screenshots/05-realtime-voice-iphone-1320x2868.png)

## Key Features

- **Network discovery** — auto-detects running agents on your local network via Iroh
- **Realtime voice** — talk to your coding agent
- **Session management** — create, resume, and manage coding sessions from your phone
- **Generative UI** — rich rendering of agent output
- **SSH fallback** — connect to remote machines via SSH port forwarding

## Build from Source

```bash
make ios-device-fast          # fast iOS device build
make ios-sim-fast             # fast iOS simulator build
make android-emulator-fast    # fast Android emulator build
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for prerequisites, full build options, TestFlight/App Store release, and SSH setup.

## Repository Layout

```
apps/ios/                  iOS app (Litter scheme, project.yml is source of truth)
apps/android/              Android app (Compose UI, Gradle build)
shared/rust-bridge/
  codex-mobile-client/     Shared Rust client crate + UniFFI surface (iOS & Android)
  codex-ios-audio/         iOS-only audio/AEC crate
shared/third_party/codex/  Upstream Codex submodule
shared/third_party/alleycat/ Alleycat daemon submodule (multi-agent bridge)
patches/codex/             Local patch set applied during builds
tools/scripts/             Cross-platform helper scripts
```

## Architecture

Both platforms share a single Rust core (`codex-mobile-client`) via UniFFI-generated bindings. Platform code (Swift/Kotlin) stays thin: UI, permissions, notifications, and platform APIs only. Session state, streaming, hydration, discovery, and auth logic live in Rust.

The companion daemon ([alleycat](https://github.com/dnakov/alleycat)) runs on your computer, spawns coding agent CLIs on demand, and multiplexes them onto a single QUIC connection. The phone connects over the local network (or via Iroh relay) and picks an agent per session.

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
| `make clean` | Remove all build artifacts |
