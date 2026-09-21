# Repository Risk Register

Open engineering risks and their required order of resolution. The living
ownership map is [ARCHITECTURE.md](ARCHITECTURE.md); this file records only what
is still outstanding.

Findings were established by an audit on 2026-08-11 using compiler, test,
Clippy, shellcheck, link, and RustSec results. A search hit or line count alone
was not treated as proof of dead code. Counts below are dated to that audit and
should be re-measured, not trusted, before acting on them.

## Alleycat dependency boundary

Alleycat is not a Litter submodule. Litter consumes selected bridge crates by
Git revision, and that revision is the production dependency surface.

The 2.1.2 candidate pins `0xSero/alleycat@d6e396c`, preserving the shipping
headless-launch lineage rather than substituting the divergent Alleycat `main`.
It refreshes native model/settings adapters, gives OMP an independent runtime,
and preserves Local Studio's explicit data directory across daemon upgrades.
Background launches avoid interactive login shells; bundled Local Studio Pi
uses plain Node rather than registering Electron as a foreground Dock app.

The preceding installed `52815dd` candidate advertised all 12 runtimes and
returned 1,402 catalog entries across the 11 model-bearing runtimes. A three-minute
process sample found no foreground worker registrations (88 valid samples,
two inspection timeouts). The final `eef1375` adapter adds Devin/Grok native
settings; its affected-crate tests passed (117), as did both live schema tests
(25 Devin and 104 Grok descriptors). The `d6e396c` follow-up also restores discovery of the signed Local Studio
bundle's native Pi settings metadata (60 documented fields; four helper and
four launcher/isolation tests passed). Final installed-host and mobile acceptance
remain required before claiming the release complete.

An Alleycat change is not in Litter until the revision, lockfile, generated
bindings, and both mobile runtimes are verified.

## P0 — dependency security

RustSec was rerun on 2026-09-21 against both candidate lockfiles after updating
Codex to 0.155.1 and applying compatible h2 0.4.16 and rustls 0.23.45 security
patches. Five advisories remain in the shared mobile lock and four in the
packaged Kittylitter lock. These are advisory counts, not affected-package counts.

- Mobile: Hickory 0.25.2 through upstream Rama DNS retains
  `RUSTSEC-2026-0119` and `RUSTSEC-2026-0118`. Moving to Hickory 0.26 requires
  an upstream dependency/API change.
- Packaged host: Iroh 0.98.2 and iroh-relay 0.98.0 pin Hickory exactly to
  0.26.0-beta.4, retaining `RUSTSEC-2026-0120` and `RUSTSEC-2026-0119`.
- Both: plist 1.9.0 through netdev/netwatch retains quick-xml 0.39.2 and
  `RUSTSEC-2026-0195` / `RUSTSEC-2026-0194`; the fixed quick-xml 0.41 line
  requires a compatible upstream plist contract.
- Mobile: RSA 0.10.0-rc.18 retains `RUSTSEC-2023-0071`, with no patched
  release reported by RustSec.

**Do not suppress these advisories.** Preserve these upstream upgrade tracks,
rerun RustSec after compatibility changes, and verify network, SSH, MCP, and
pairing on installed devices. A successful build is not physical-device network
acceptance. Mobile uses Iroh 1.0.3 and Russh 0.62.6; the separately packaged host's
Iroh version above must not be confused with the mobile dependency.

## P1 — incomplete user-visible behavior

- Android Ghostty loads after the GLAD/EGL/GLES linking repair, but its OpenGL
  4.3 renderer cannot create a surface on the tested Android 17 emulator's
  OpenGL ES 3.1 context. The basic terminal command field supports line input
  and output; native rendering, ANSI screen semantics, selection, and full-screen
  terminal applications still require a proper OpenGL ES port and device QA.
- Android's realtime speaker control updates a boolean but does not switch the
  physical audio route. `RealtimeWebRtcSession` forces speakerphone on at session
  start and restores the previous route at teardown; the toggle never reaches
  `AudioManager`.
- Realtime input/output meters do not use actual audio-level telemetry on either
  platform.
- Voice handoff cannot select an arbitrary existing thread through one typed
  end-to-end contract.
- Android lacks the plugin/file `@` autocomplete behavior recorded in its QA
  matrix.
- Windows SSH/direct fallback remains incomplete; detached SSH bridge launch is
  explicitly unimplemented for PowerShell remotes.
- Realtime response cancellation is observable in the bundled Codex runtime but
  is not exposed by its app-server protocol, so Watch offers only the supported
  stop control. A true barge-in action awaits that upstream request.
- ACP cannot truthfully implement direct `command/exec`, terminate, stdin, or
  resize without a session-bearing Codex request. Fork currently creates a new
  ACP session projection; it does not clone complete server-side history.
- Several Pi/Claude bridge status/config/skills/MCP responses are intentionally
  synthesized or empty and require live conformance coverage before expansion.
- Android's `Route.Sessions` screen subtree (`SessionsScreen`, `SessionsUiState`,
  `SessionsDerivation`, and the `Route.ServerInfo` /
  `Route.ServerWallpaper*` branches nested under it) still compiles but is
  unreachable: `Route.Sessions` is never constructed. Either re-wire an entry
  point or delete the subtree; do not QA it as shipping behavior.
- Android's `HomeAppTakeoverRow` and its `savedAppsByThread` / `sessionApps`
  feeder pipeline are built but never rendered. The grouping work runs on every
  home snapshot tick to populate an unread local.

Each voice item is device-gated. A green unit test is not proof that speaker
routing, metering, Bluetooth, interruption, or handoff works on hardware.

## P1 — concentration and state risk

The highest-maintenance files remain the Rust reducer, `MobileClient`, the
handwritten FFI client, the parser, iOS `ConversationView`, and Android's
conversation timeline. Together they centralize unrelated responsibilities and
make review difficult. Split them only at typed ownership seams with replay
fixtures; a line-count-only extraction would increase risk.

The strict Clippy run leaves 30 structural findings in `codex-mobile-client`:
UniFFI constructor/default shape, large public result or command variants,
high-arity boundary methods, two complex internal types, and test-module
placement. These should remain visible until the boundary design is changed;
blanket allows would erase useful architecture signals.

## P2 — repository and release maintenance

- The shared Cargo manifest tracks `ish-embed-host` from a moving `main` branch
  while the lockfile pins one commit. Replace it with an explicit revision or
  release after local-runtime acceptance.
- `mobile-release.yml` is a large, duplicated release-control surface. Manual,
  automatic, distribution, TestFlight, and Play paths are distinct acceptance
  surfaces, but shared setup and artifact verification should be factored into
  reusable workflows.
- `services/kittylitter` publishes v0.3.6 metadata. The release guard correctly
  rejects changing that package after its tag; update it only with a coordinated
  version bump.
- Android's three custom `buildConfigField`s (`RUNTIME_STARTUP_MODE`,
  `APP_RUNTIME_TRANSPORT`, `ENABLE_ON_DEVICE_BRIDGE`), the two matching
  `manifestPlaceholders`, and the two `<meta-data>` tags they feed form a closed
  loop: no production Kotlin reads any of them, and no code calls
  `PackageManager.GET_META_DATA`. `RuntimeFlavorConfigTest` asserts these
  constants against values hardcoded in the same Gradle file, so it tests the
  build system rather than the app.
- Historical Git objects still contain a roughly 82 MB shared-library object,
  leaving a roughly 130 MB pack. Removing it requires a coordinated history
  rewrite and is intentionally outside routine cleanup.
- The iOS and Android `home_cat.webp` / `home_cat_entrance.webp` pairs are
  byte-identical across platforms (~4.5 MB of tracked duplication). No other
  tracked asset justifies a conversion-only cleanup wave.
- Markdown lint reports hundreds of existing line-length/table-layout issues,
  mainly in `AGENTS.md` and the Android QA matrix. Relative local links pass. Fix
  formatting when those documents are otherwise edited; do not generate a
  review-obscuring reflow-only commit.
- Android lint reports zero errors, 105 warnings, and 14 hints. Most are KTX
  modernization suggestions and coordinated dependency upgrades. The deliberate
  synchronous encrypted-preference commits, adaptive icon API qualifier, ChromeOS
  ABI gap, and complex Droid vector remain visible. Do not confuse this clean
  error gate with physical Android acceptance.

## Retained despite having no callers

Lack of an internal caller is not proof of removability. These are retained
deliberately:

  dead code. Superseded SSH and realtime boundary wrappers require live mobile
  acceptance before any later removal.
- `tools/scripts/codex-e2e-proof.sh`, `tools/scripts/local-studio-e2e-proof.sh`,
  and their shared `tools/scripts/assert-local-studio-proof.py` are operator
  acceptance harnesses driven by a locally built `kittylitter` binary. Nothing in
  the Makefile, CI, or docs invokes them; they are run by hand.

## Recommended execution waves

1. **Security compatibility.** Iroh/Hickory and Russh/SHA-2 are upgraded. Next,
   upgrade upstream Codex/RMCP and track plist/quick-xml plus RSA owners. Gate
   each change with RustSec, host tests, both mobile builds, and physical
   network/SSH/MCP checks.
2. **Alleycat lineage.** Reconcile the production pin's 56-commit lineage onto
   Alleycat `main`, run live bridge conformance, then update Litter's explicit
   revision.
3. **Voice hardware.** Implement real route selection and level telemetry in
   native WebRTC adapters, add the typed existing-thread handoff contract in
   Rust, and validate interruption/Bluetooth/speaker behavior on iOS and Android
   devices.
4. **Android reachability.** Decide the fate of the `Route.Sessions` subtree and
   the saved-app home takeover, then remove the dead runtime-flavor build config
   loop.
5. **Conversation decomposition.** Capture replay fixtures and profiling first;
   then extract render-only sections, hydration boundaries, and reducer domains
   without creating native shadow state.
6. **Release reuse.** Extract shared workflow setup and artifact assertions,
   keeping store ownership, signing, installed runtime, and live endpoint gates
   distinct.
7. **Asset/history maintenance.** Schedule any Git history rewrite as a separate
   coordinated migration.

## Acceptance gates

Shared-behavior changes are not accepted on source review alone. The minimum
stack is:

1. full `codex-mobile-client` host test suite;
2. `codex-slingshot` tests and shellcheck templates;
3. UniFFI binding regeneration;
4. iOS simulator or device build;
5. Android unit tests, debug APK assembly, and lint with zero errors; and
6. physical-device verification for audio, networking, local runtimes, and
   release-only behavior.

Live external-agent conformance remains opt-in. Physical-device voice, network,
local-runtime, and store-release acceptance remain separate gates.
