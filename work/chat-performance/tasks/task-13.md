# Task 13 — Bound reconnect and hydration

## Session

`chat-w03-s13-reconnect-and-hydration` · Wave 3 · implementation.

## Objective

Make recovery prioritize the visible conversation, cap concurrency and cloning, eliminate duplicate platform reconnect passes, and keep legacy lifecycle normalization evidence-gated at the wire boundary.

## Files Involved

- `shared/rust-bridge/codex-mobile-client/src/session/connection.rs` — reconnect ownership/backoff.
- `src/store/` and `src/conversation.rs` — prioritized hydration and reconciliation.
- `src/recorder.rs` — reconnect/hydration replay fixtures.
- `shared/rust-bridge/codex-slingshot/src/json_line_wire.rs` — legacy normalization only if captured frames require it.
- Thin iOS/Android lifecycle callers that currently initiate duplicate work.

## Changes

- Establish one Rust-owned reconnect attempt with exponential backoff, jitter, cancellation, and generation fencing.
- Hydrate the visible thread first, then bounded background work; avoid repeated full-history cloning.
- Coalesce duplicate network/lifecycle triggers from both platforms.
- Preserve sessions across reconnect/hydration; only explicit archive removes one.
- Normalize legacy events only before strict decode and only from scrubbed captured evidence.

## Tests

- Duplicate trigger, stale-generation, disconnect-during-hydration, and cancellation tests.
- Visible-first ordering, bounded-concurrency, 1,500-item memory, and partial-failure tests.
- Replay fixtures for modern and evidenced legacy lifecycle frames.
- iOS/Android lifecycle integration tests proving one reconnect pass.

## Validation

```sh
make rust-test
make ios-sim-fast
make android-emulator-fast
```

## Acceptance Criteria

- Reconnect-to-live-delta p95 is at or below 800 ms for the client-controlled share.
- Hydration concurrency and retry behavior are explicitly bounded and measured.
- No duplicate Android/iOS recovery pass and no session loss across recovery.
