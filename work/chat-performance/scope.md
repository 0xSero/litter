# Scope: Litter chat performance

## Goal

Execute the wave plan in [`GOAL.md`](../../GOAL.md) until Litter chat is measurably immediate, frame-stable, and robust on iOS and Android, with shared behavior owned in Rust and installed-runtime evidence on both platforms.

## Context

The current chat path already has useful incremental caches and some candidate repairs, but it has no end-to-end performance ledger. `origin/main` is the authoritative base. An unmerged candidate branch contains queue serialization, display-cadence batching, lifecycle compatibility, and release metadata; Wave 0 must validate and disposition those commits before adding overlapping work.

## Current State (What Exists)

- Shared store and update boundary: `shared/rust-bridge/codex-mobile-client/src/store/`, `src/ffi/app_store.rs`, and `src/mobile_client/`.
- iOS state and chat UI: `apps/ios/Sources/Litter/Models/AppModel.swift`, `Views/ConversationScreenModel.swift`, `Views/ConversationView.swift`, and `Views/ConversationTimelineView.swift`.
- Android state and chat UI: `apps/android/app/src/main/java/com/litter/android/state/AppModel.kt` and `ui/conversation/`.
- Existing Rust subscription coalescing drains currently-ready deltas, but authoritative timing and device impact are unmeasured on `origin/main`.
- Per-delta platform code still risks whole-snapshot copying, broad observation, transcript re-derivation, and scroll feedback.
- Existing tools include store update recording, KittyLitter end-to-end probes, iOS xctrace runners, and mobile CI.
- No committed chat-specific p50/p95/p99 baseline or installed two-turn/tool performance gate exists.

## Target State (What Changes)

- Deterministic replay and end-to-end spans identify client latency by stage.
- Active streaming updates are narrow, paced, and do not mutate the whole app snapshot every token.
- Scroll following is conflated, non-animated during streaming, and respects user drag.
- Queue reservation, request/event concurrency, reconnect, and hydration are bounded and testable.
- Renderer optimizations are admitted only after profiles identify them.
- Each wave lands as independently validated, reversible commits and finishes through synchronized protected main.

## Integration Plan

1. Reconcile unmerged candidate repairs against `origin/main` and freeze the Wave 0 base.
2. Add deterministic replay, spans, platform tracing, and initial regression gates without behavior changes.
3. Remove per-token state amplification across shared Rust, iOS, and Android.
4. Stabilize platform scrolling and profile-gated rendering.
5. Bound queues, transport, reconnect, and hydration.
6. Validate on physical iOS and Android devices, harden CI, and merge through protected main.

## Testing Plan

- Unit: reducer transitions, pacing, narrow projections, streaming buffers, follow-tail state, timeout/backoff, and lifecycle normalization.
- Integration: deterministic store replay, rapid double-send, slow-RPC-with-live-events, reconnect, paginated hydration, and queue retry.
- E2E: KittyLitter probe scenarios plus installed iOS and Android two-turn/tool flows.
- Performance: Rust smoke benchmarks, iOS signpost/xctrace captures, Android Perfetto/JankStats captures, and small committed summary artifacts.
- Coverage: newly added or materially changed pure modules require strict branch coverage; platform glue must have targeted behavior tests and installed-runtime acceptance.

## Non-goals

- Upstream Codex submodule edits, protocol/schema migrations, speculative architecture rewrites, Markdown engine replacement, or unrelated release work.

## Risks & Mitigations

- Candidate repairs may conflict with current main: use a commit disposition matrix and cherry-pick only validated commits.
- Pacing can hurt TTFT: first delta after idle must bypass the pacing window and is separately gated.
- Narrow observation can create stale secondary surfaces: document cadence and flush on turn settle.
- Scroll correctives may encode real layout workarounds: remove them only with device evidence covering code, math, and images.
- Device timing is noisy: compare repeated distributions and committed fixture versions, not single runs.

## Assumptions

- Rapid second send queues rather than steering or starting parallel work.
- One-second freshness is acceptable for watch/widget secondary surfaces during an active stream, with an immediate settle flush.
- Physical performance floors are approximately iPhone 12/SE-3 and Pixel 6a/7a class unless the coordinator records a replacement.
- The normal protected-main workflow, rather than direct unreviewed pushes, performs final integration.
