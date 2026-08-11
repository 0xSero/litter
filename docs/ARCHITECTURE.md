# Litter Architecture

This is the ownership map for the shipping iOS and Android clients. It is
descriptive, not aspirational: when code and this document disagree, treat the
code as a bug or update this document in the same change.

## Runtime shape

```text
SwiftUI / Compose
       │
       │ thin platform projection
       ▼
Swift AppModel / Kotlin AppModel
       │
       │ generated UniFFI bindings
       ▼
codex-mobile-client (Rust)
  ├─ AppStore + reducer + snapshots
  ├─ MobileClient session/runtime facade
  ├─ AppClient direct RPC surface
  ├─ reconnect and SSH
  ├─ hydration and conversation shaping
  ├─ voice handoff state machine
  └─ terminal, local runtime and platform hooks
       │
       ├─ patched upstream Codex app-server client/core
       ├─ Alleycat agent bridges
       ├─ codex-slingshot JSON-line/HTTP stream transport
       └─ Ghostty terminal engine
```

`shared/rust-bridge/codex-mobile-client` is the only public mobile Rust crate.
It exposes one handwritten UniFFI API to both platforms. Generated Swift and
Kotlin are build products, not independently maintained implementations.

## State and request ownership

`AppStoreReducer` owns canonical mobile runtime state. Its snapshots include
servers, threads, session summaries, live item projections, terminal sessions,
connection progress and voice state. Upstream notifications are reduced first;
targeted reads reconcile gaps where the upstream event stream is insufficient.

`AppStore` is the subscription and snapshot boundary. It should contain only
store-local or composite actions. `AppClient` owns direct server operations
such as thread start/read/resume, turns, account calls, models and skills.

The native `AppModel` on each platform:

- constructs the Rust objects once;
- subscribes to typed `AppStoreUpdateRecord` values;
- projects snapshots into observable Swift/Kotlin state;
- schedules UI refresh and hydration work; and
- owns platform-only persistence, permissions and services.

It must not parse upstream wire strings or maintain a second reducer.

## Server and transport flow

1. Add Server selects an explicit Kittylitter, Local Studio,
   connected-computer, direct URL or SSH path.
2. A server connection selects the appropriate direct, SSH, Alleycat or local
   runtime transport.
3. `MobileClient` owns live sessions and routes typed requests/events.
4. Events are hydrated into mobile conversation items and reduced into
   `AppStore`.
5. SwiftUI or Compose re-renders from the typed snapshot/update stream.

iPhone first-launch nearby-Mac pairing uses the separate `_litter-pair._tcp.`
Bonjour service. Swift owns that platform browse; Rust owns only the pair
protocol and resulting saved-server/session flow. Neither platform runs a
general LAN, Tailscale, Codex Bonjour, SSH Bonjour or ARP discovery scan.

`codex-slingshot` adapts JSON-line and HTTP stream transports to the same RPC
wire abstraction used by the patched Codex app-server client. SSH bootstrap,
reconnect policy and server normalization stay in Rust.

## Conversation lifecycle

Thread lists populate summaries first. Activating a thread selects a
`ThreadKey(server_id, thread_id)` and schedules a read/resume when the cached
snapshot is insufficient. Streaming notifications update individual items or
append typed deltas. Coalescing is bounded so high-rate command/reasoning
updates do not force a full native snapshot for every token.

The principal code is:

- `src/store/` — reducer, snapshots, boundary projection and typed updates;
- `src/mobile_client/` — sessions, request routing and runtime coordination;
- `src/ffi/client.rs` — handwritten direct RPC boundary;
- `src/conversation.rs` and `src/hydration.rs` — item shaping;
- `src/session/` — connection worker, event routing and voice handoff; and
- `src/parser.rs` — presentation-oriented message structure.

## Local execution

iOS embeds an Alpine/iSH runtime. Android embeds Alpine under proot. The Codex
submodule patch redirects process execution through platform hooks because
normal `fork`/`exec` is not available in the mobile sandboxes. Rust owns argv
preflight, temporary-path rewriting and bundled-tool resolution; native code
only supplies platform bootstrap inputs.

## Terminal

Ghostty is patched as an embedded terminal engine. Rust owns terminal state,
SSH/local backends, OSC parsing and render data. Swift and Kotlin own the view
and native input surface. The exact Zig version comes from Ghostty's
`build.zig.zon` and is resolved by `tools/scripts/resolve-ghostty-zig.sh`.

## Realtime voice

Native libwebrtc owns audio capture/playback, AEC, noise suppression and the
peer connection. Rust owns realtime signaling state, typed transcripts,
dynamic-tool routing and `HandoffManager`. The patched Codex protocol allows
client-controlled handoff resolution and finalization.

Current gaps are explicit:

- Android's speaker toggle does not yet change the active audio route;
- the visible input/output meters are not backed by real level telemetry; and
- selecting an arbitrary existing thread for a voice handoff is not yet a
  typed end-to-end contract.

These require device-level acceptance; do not simulate completion in platform
state.

## Platform code

iOS lives under `apps/ios/Sources/Litter`:

- `Views/` — SwiftUI and render-only projections;
- `Models/` — platform controllers, persistence and the observation shell;
- `Bridge/` — thin UniFFI/platform adapters; and
- `CarPlay/` and `MacCommands/` — Apple-only integrations.

Android lives under `apps/android/app/src/main/java/com/litter/android`:

- `ui/` — Compose shell and screens;
- `state/` — the Kotlin observation shell and platform services; and
- `service/`, `voice/` and related packages — Android APIs and lifecycles.

`apps/android/core/bridge` contains JNI bootstrap only. Android has exactly two
Gradle modules: `:app` and `:core:bridge`.

## Generated and vendored code

- `apps/ios/project.yml` is the Xcode project source of truth.
- `shared/rust-bridge/generated/{swift,kotlin}` is regenerated by
  `shared/rust-bridge/generate-bindings.sh` and is not copied into Android.
- `apps/ios/GeneratedRust` and `apps/ios/Frameworks` are local build products.
- `shared/third_party/codex` and `shared/third_party/ghostty` are submodules.
- `patches/codex` and `patches/ghostty` are superproject-owned source changes;
  do not commit the applied submodule worktrees.

## Alleycat dependency boundary

Litter consumes selected Alleycat bridge crates by Git revision. That revision
is the production dependency surface; Alleycat's own `main` branch is a
separate acceptance surface. An Alleycat change is not in Litter until the
revision, lockfile, generated bindings and both mobile runtimes are verified.

## Build and verification lanes

The root Makefile is authoritative. Fast lanes emit raw per-platform Rust
libraries; package lanes build the full distributable artifacts. Build stamps
include source prerequisites and patch manifests, so deleting a stamp is not a
substitute for declaring a real dependency.

For shared behavior, the minimum acceptance stack is:

1. Rust unit/integration tests;
2. UniFFI binding generation;
3. iOS simulator or device build;
4. Android unit tests and APK assembly; and
5. physical-device verification for audio, networking, local runtimes and
   release-only behavior.

## Maintenance boundaries

The largest current concentration risks are the reducer, `MobileClient`, the
direct FFI client, the parser, iOS `ConversationView`, and Android conversation
timeline. Split these only along ownership seams with replay fixtures and
behavioral tests; line-count-only refactors are not an acceptance gate.

Before adding native logic, ask whether both clients need it. If they do, add a
typed Rust record/enum and one shared implementation. Before adding a method to
`AppStore`, ask whether it is a direct server request that belongs on
`AppClient`. Before adding cache state, ask whether it is canonical runtime
state that belongs in the reducer.
