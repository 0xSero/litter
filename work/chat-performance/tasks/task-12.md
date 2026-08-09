# Task 12 — Make queueing and transport non-blocking

## Session

`chat-w03-s12-queue-and-transport` · Wave 3 · implementation.

## Objective

Guarantee atomic rapid-send semantics and ensure slow outbound RPCs never block inbound event ingestion, with explicit timeouts and retry ownership.

## Files Involved

- `shared/rust-bridge/codex-mobile-client/src/mobile_client/mod.rs` — turn reservation/send decision.
- `src/mobile_client/store_listener.rs` — queued draft flush and retry.
- `src/store/reducer.rs` and `snapshot.rs` — reservation/queue state machine.
- `src/session/connection.rs` and transport modules — request/event-loop separation and timeouts.
- `shared/rust-bridge/codex-mobile-client/tests/` — concurrency and fault-injection tests.

## Changes

- Make check-and-reserve atomic so simultaneous sends cannot both start.
- Preserve FIFO queued drafts and retry a failed flush without waiting for another completion event.
- Separate outbound request completion from the global inbound reader/event publisher.
- Add bounded timeouts and cancellation semantics to start, steer, resume, and turn-list operations.
- Reconcile authoritative events after timeout rather than guessing platform state.

## Tests

- Barrier-controlled two-send race: exactly one active start and one queued draft.
- FIFO queue, transient failure, retry, cancellation, timeout, disconnect, and duplicate-completion tests.
- Slow-RPC fault injection proving deltas continue uninterrupted.
- Deterministic replay of queue and lifecycle transitions.

## Validation

```sh
cargo test --manifest-path shared/rust-bridge/Cargo.toml -p codex-mobile-client
make rust-test
```

## Acceptance Criteria

- Rapid double-send is deterministic under repeated concurrency stress.
- Queued turn starts within 150 ms p95 after completion in the baseline environment.
- Slow or timed-out RPCs do not stall inbound deltas or require platform-side state patching.
