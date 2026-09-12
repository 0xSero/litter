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

At audit time Litter's production pin was `417f2a9` while Alleycat `main` was
`3f0f844`; their merge base was `3c6dfe2` and the production pin had 56 commits
not present on `main`. **Alleycat `main` is therefore not the shipping source of
truth.** Advancing Litter to it would regress the shipping bridge stack. Merge or
replay the pinned lineage into Alleycat first, then advance Litter's revision
through both mobile acceptance lanes.

An Alleycat change is not in Litter until the revision, lockfile, generated
bindings, and both mobile runtimes are verified.

## P0 — dependency security

As of the audit, RustSec reported nine advisories for the shared mobile lock,
two for Alleycat `main`, and four for the packaged `kittylitter` lock (which
still follows Litter's older production Alleycat revision).

The unresolved advisories are rooted in dependency contracts that require
coordinated upgrades rather than a lockfile-only refresh:

- upstream Codex 0.132 pins an older quick-xml, RMCP 0.15, and a Hickory 0.25
  network-proxy chain;
- Iroh 1.0.3 still reaches quick-xml 0.39 through the current plist contract;
  the fixed quick-xml 0.41 line is not semver-compatible with that dependency;
- two RSA versions have no fixed release in their current dependency lines.

**Do not suppress these advisories.** The next release wave should upgrade
Codex/RMCP and track the plist/quick-xml and RSA owners, rerun RustSec after each
compatibility change, and finish with installed-device network, SSH, MCP, and
pairing tests.

Iroh 1.0.3 and Russh 0.62.6 are in place and their source/test gates are green,
but their network and SSH behavior still requires physical-device acceptance.

## P1 — incomplete user-visible behavior

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
