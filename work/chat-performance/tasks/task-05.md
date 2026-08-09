# Task 05 — Narrow shared active-stream state

## Session

`chat-w01-s05-shared-stream-state` · Wave 1 · implementation.

## Objective

Remove shared-Rust per-token whole-state amplification while preserving immediate first-token delivery, deterministic replay, and the public UniFFI contract needed by both platforms.

## Files Involved

- `shared/rust-bridge/codex-mobile-client/src/store/reducer.rs` — active-item mutation and reconciliation.
- `shared/rust-bridge/codex-mobile-client/src/store/snapshot.rs` — snapshot/summary construction.
- `shared/rust-bridge/codex-mobile-client/src/ffi/app_store.rs` — subscriber update boundary.
- `shared/rust-bridge/codex-mobile-client/src/conversation.rs` and `conversation_uniffi.rs` — typed stream projection.
- `shared/rust-bridge/codex-mobile-client/tests/` — replay, allocation, and emit-cost coverage.

## Changes

- Introduce the smallest typed active-thread/active-item update that avoids cloning unrelated sessions and conversations.
- Keep bounded text accumulation and flush immediately for the first delta, completion, approval, error, and queue transitions.
- Preserve authoritative event ordering and force a full resync after subscriber lag.
- Keep public UniFFI handwritten and narrow; regenerate bindings rather than editing generated sources.

## Tests

- Golden replay equivalence before and after the update-boundary change.
- Subscriber lag/full-resync, completion flush, approval, error, and first-delta tests.
- 1,500-item reduce/emit benchmark plus allocation-growth regression test.

## Validation

```sh
make bindings
cargo test --manifest-path shared/rust-bridge/Cargo.toml -p codex-mobile-client
make rust-check
```

## Acceptance Criteria

- Unrelated app/session state is not cloned or emitted for each delivered token.
- Reduce and emit p95 is at or below 2 ms on the baseline machine and fixture.
- Replay final snapshots and externally visible ordering remain identical.
