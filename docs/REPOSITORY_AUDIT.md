# Repository Audit — 2026-08-11

This is a dated engineering audit of Litter and its Alleycat runtime dependency.
The living ownership map is [ARCHITECTURE.md](ARCHITECTURE.md); this file records
the cleanup evidence, remaining risks, and the order in which to address them.

## Scope and method

- Litter was reviewed from `origin/main` at `5f651a47`.
- Alleycat was reviewed from `origin/main` at `3f0f844` in a clean authority
  worktree. The user's separate Alleycat feature worktree was not modified.
- Tracked files, ignored build products, Git history size, dependency locks,
  Swift/Kotlin/Rust ownership, scripts, CI, assets, and Markdown references were
  inventoried separately.
- Pi read-only sessions used
  `deepseek-v4-flash-0731 / ds4/deepseek-v4-flash-dspark` at high reasoning,
  divided by iOS, Android, shared Rust, voice, build/release, documentation,
  and Alleycat bridge boundaries. The retained session logs contain 268
  explicit Pi `read` calls: 183 Litter paths, 58 Alleycat paths, and 27
  configuration/support paths, in addition to manifest and shell reads.
- The provider later began ending new streams without a `finish_reason`.
  Findings from completed reads were retained; interrupted sessions were not
  represented as completed reviews or final verdicts.
- Compiler, test, Clippy, shellcheck, link, and RustSec results were used as
  evidence. A search hit or line count alone was not treated as proof of dead
  code.

The Litter baseline contained 1,027 tracked paths. Alleycat contained 282.
Binary assets and generated products were inventoried but are not described as
"lines of code." Applied Codex and Ghostty patches make their submodule
worktrees dirty by design; those changes belong to the superproject patch set
and must not be committed inside either submodule.

At the final audit checkpoint Litter contains 1,008 tracked paths and Alleycat
contains 281. The only intentionally dirty Litter paths are the two applied
submodule worktrees; no top-level untracked source or loose audit artifact is
left behind. The user's separate dirty Alleycat worktree remains untouched.

## Architecture conclusions

The shipping clients have one canonical runtime state owner:
`codex-mobile-client` in Rust. Swift and Kotlin project typed snapshots into
their UI frameworks and own only platform APIs. Direct server requests belong
on `AppClient`; canonical state and reconciliation belong in the Rust store.

The runtime path is:

```text
SwiftUI / Compose
  -> native AppModel observation shell
  -> generated UniFFI boundary
  -> Rust AppStore / MobileClient / AppClient
  -> Codex, Alleycat, SSH, local runtime, or slingshot transport
```

Alleycat is not a Litter submodule. Litter consumes selected bridge crates by
Git revision. At audit time, Litter's production pin was `417f2a9`, while
Alleycat `main` was `3f0f844`; their merge base was `3c6dfe2` and the production
pin had 56 commits not present on `main`. Alleycat `main` is therefore not the
shipping source of truth until that history is reconciled and Litter advances
its pin through both mobile acceptance lanes.

## Cleanup completed in this audit

The audit branch is net-negative even after adding this architecture record.
The validated changes include:

- removed stale local artifacts and an obsolete Android runtime flavor/tooling
  path;
- removed the unused legacy voice-handoff compatibility layer while retaining
  the active typed `HandoffManager` path;
- removed both superseded full-screen voice-call implementations, four more
  unreachable iOS/Android view files, two unused Android resources, one unused
  Android logo, and 25 dead Android strings;
- removed the redundant npm lock from the Bun-owned push proxy and unused Rust
  dependency declarations until Cargo Machete was clean in both workspaces;
- generated UniFFI's API-aware Android cleaner instead of an Android-13-only
  JVM cleaner, and fixed every hard Android lint error without a baseline;
- removed redundant directory READMEs, a completed monorepo migration plan,
  machine-specific screenshot notes with broken links, and the obsolete
  realtime-resume design document;
- removed the lone manifest for an Android Gradle module that no longer exists;
- made the Codex patch directory the authoritative Make/sync invalidation
  manifest instead of maintaining a second stale filename list;
- pinned Ghostty's exact Zig toolchain contract and repaired fresh-checkout
  prerequisite checks;
- cleared app-owned Swift warnings, slingshot lint debt, shell-script hazards,
  and mechanical shared-client Clippy findings;
- corrected Android QA, platform quickstarts, repository layout, patch
  ownership, and build target documentation;
- restored hermetic Alleycat bridge tests and removed workspace-wide Clippy
  debt; and
- replaced Alleycat ACP documentation that contradicted its own implementation,
  while changing an unroutable terminal-termination false success into an
  explicit unsupported-method result;
- upgraded Litter and Alleycat to Iroh 1.0.3, replacing the vulnerable Hickory
  beta line with 0.26.1 and the release-candidate SHA-2 stack with stable
  releases; and
- upgraded Litter's direct SSH stack to Russh 0.62.6, removing both unbounded
  allocation advisories and the obsolete workspace-only `russh-keys` entry.

Against their starting `origin/main` revisions, Litter is 4,303 net lines
smaller (1,170 additions and 5,473 deletions across 146 paths), while Alleycat
is 520 net lines smaller (991 additions and 1,511 deletions across 85 paths).

## Priority findings

### P0 — dependency security and release ownership

RustSec initially reported 19 vulnerabilities in Litter's shared mobile lock,
and six each in Alleycat and the packaged `kittylitter` lock. Patch-compatible
updates removed the crossbeam pointer issue, the locked QUIC reassembly issue,
and Litter's two rustls-webpki certificate-validation issues. The Iroh 1.0.3
and Russh 0.62.6 compatibility updates then removed the Hickory beta and SSH
allocation advisories. The remaining counts are nine for the broad Litter
lock, two for Alleycat `main`, and four for the packaged `kittylitter` lock,
which still follows Litter's older production Alleycat revision.

The unresolved advisories are rooted in dependency contracts that require
coordinated upgrades rather than a lockfile-only refresh:

- upstream Codex 0.132 pins an older quick-xml, RMCP 0.15, and a Hickory 0.25
  network-proxy chain;
- Iroh 1.0.3 still reaches quick-xml 0.39 through the current plist contract;
  the fixed quick-xml 0.41 line is not semver-compatible with that dependency;
- two RSA versions have no fixed release in their current dependency lines.

Do not suppress these advisories. The next release wave should upgrade
Codex/RMCP and track the plist/quick-xml and RSA owners, rerun RustSec after
each compatibility change, and finish with installed-device network, SSH, MCP,
and pairing tests. The Iroh and Russh source/test gates are green, but their
network and SSH behavior still requires physical-device acceptance.

Alleycat production history must also be reconciled onto `main`. Advancing
Litter to the current Alleycat `main` would regress the shipping bridge stack;
merging or replaying the pinned lineage into Alleycat first is the safe order.

### P1 — incomplete user-visible behavior

- Android's realtime speaker control updates state but does not switch the
  physical audio route.
- Realtime input/output meters do not use actual audio-level telemetry on both
  platforms.
- Voice handoff cannot select an arbitrary existing thread through one typed
  end-to-end contract.
- Android lacks the plugin/file `@` autocomplete behavior recorded in its QA
  matrix.
- Windows SSH/direct fallback remains incomplete.
- ACP cannot truthfully implement direct `command/exec`, terminate, stdin, or
  resize without a session-bearing Codex request. Fork currently creates a new
  ACP session projection; it does not clone complete server-side history.
- Several Pi/Claude bridge status/config/skills/MCP responses are intentionally
  synthesized or empty and require live conformance coverage before expansion.

Each voice item is device-gated. A green unit test is not proof that speaker
routing, metering, Bluetooth, interruption, or handoff works on hardware.

### P1 — concentration and state risk

The highest-maintenance files remain the Rust reducer, `MobileClient`, the
handwritten FFI client, the parser, iOS `ConversationView`, and Android's
conversation timeline. Together they centralize unrelated responsibilities and
make review difficult. Split them only at typed ownership seams with replay
fixtures; a line-count-only extraction would increase risk.

The strict Clippy run now leaves 30 structural findings in
`codex-mobile-client`: UniFFI constructor/default shape, large public result or
command variants, high-arity boundary methods, two complex internal types, and
test-module placement. These should remain visible until the boundary design is
changed; blanket allows would erase useful architecture signals.

### P2 — repository and release maintenance

- The shared Cargo manifest tracks `ish-embed-host` from a moving `main` branch
  while the lockfile pins one commit. Replace it with an explicit revision or
  release after local-runtime acceptance.
- `mobile-release.yml` is a large, duplicated release-control surface. Manual,
  automatic, distribution, TestFlight, and Play paths are distinct acceptance
  surfaces, but shared setup and artifact verification should be factored into
  reusable workflows.
- Large cat animations remain the main tracked asset opportunity. Existing
  compression changes must be judged in the real Android renderer before
  merging.
- Historical Git objects still contain a roughly 82 MB shared-library object,
  leaving a roughly 130 MB pack. Removing it requires a coordinated history
  rewrite and is intentionally outside this cleanup.
- Markdown lint reports hundreds of existing line-length/table-layout issues,
  mainly in `AGENTS.md` and the Android QA matrix. Relative local links pass.
  Fix formatting when those documents are otherwise edited; do not generate a
  review-obscuring reflow-only commit.
- Android lint now reports zero errors, 105 warnings, and 14 hints. Most are
  KTX modernization suggestions and coordinated dependency upgrades. The
  deliberate synchronous encrypted-preference commits, adaptive icon API
  qualifier, ChromeOS ABI gap, and complex Droid vector remain visible. Do not
  confuse this clean error gate with physical Android acceptance.
- Cargo Machete 0.9.2 reports no unused dependencies in either Rust workspace
  after the audited manifest cleanup.

## Recommended execution waves

1. **Security compatibility.** Iroh/Hickory and Russh/SHA-2 are upgraded. Next,
   upgrade upstream Codex/RMCP and track plist/quick-xml plus RSA owners. Gate
   each change with RustSec, host tests, both mobile builds, and physical
   network/SSH/MCP checks.
2. **Alleycat lineage.** Reconcile the production pin's 56-commit lineage onto
   Alleycat `main`, preserve the user's local Design A cleanup, run live bridge
   conformance, then update Litter's explicit revision.
3. **Voice hardware.** Implement real route selection and level telemetry in
   native WebRTC adapters, add the typed existing-thread handoff contract in
   Rust, and validate interruption/Bluetooth/speaker behavior on iOS and
   Android devices.
4. **Conversation decomposition.** Capture replay fixtures and profiling first;
   then extract render-only sections, hydration boundaries, and reducer domains
   without creating native shadow state.
5. **Release reuse.** Extract shared workflow setup and artifact assertions,
   keeping store ownership, signing, installed runtime, and live endpoint gates
   distinct.
6. **Asset/history maintenance.** Validate compressed animations on hardware;
   schedule any Git history rewrite as a separate coordinated migration.

## Validation evidence

The audit branch has passed the following relevant gates:

- full `codex-mobile-client` host test suite;
- `codex-slingshot` tests and shellcheck templates;
- iOS fast simulator build after project generation;
- Android unit tests, debug APK assembly, and lint with zero errors;
- Android-safe UniFFI Kotlin binding regeneration;
- Alleycat workspace tests across all targets;
- Alleycat workspace Clippy with warnings denied;
- ACP crate tests and Clippy with warnings denied;
- Kittylitter locked dependency check;
- local Markdown relative-link verification; and
- RustSec scans of all three product lockfiles.

The configured live documentation crawler could not run because its Kimi model
was unavailable. Local Markdown, reference, and link checks remain the evidence
for this audit; no live-site crawl is claimed.

Live external-agent conformance remains opt-in and physical-device voice,
network, local-runtime, and store-release acceptance remain separate gates.
