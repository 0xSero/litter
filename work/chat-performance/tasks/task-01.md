# Task 01 — Add shared replay and latency observability

## Delegated Mission

`pi-chat-w00-m01-rust-observability` · Wave 0 · implementation.

## Objective

Create deterministic shared-Rust replay, end-to-end send/store/transport spans, and CI-safe performance smoke tests without changing chat behavior.

## Files Involved

- `shared/rust-bridge/codex-mobile-client/src/recorder.rs` — fixture capture/replay foundation.
- `src/store/reducer.rs` — reduce, append, summary, and emit spans.
- `src/ffi/app_store.rs` — subscription coalescer counters and timing.
- `src/mobile_client/mod.rs` — send/local-overlay/queue decision phases.
- `src/session/connection.rs` — request, response, first-event, timeout, and reconnect spans.
- `shared/rust-bridge/codex-mobile-client/tests/` and `.github/workflows/mobile-ci.yml` — replay and smoke gates.

## Changes

- Define stable correlation IDs and monotonic timestamps without logging message content.
- Record update kind, byte count, item count, queue depth, coalescing count, lag/full-resync count, and phase durations.
- Add scrubbed fixtures for 10/100/500/1,500 items, long text, tools, reasoning, code/math/images, burst, reconnect, and rapid double-send.
- Add deterministic final-snapshot assertions and non-flaky smoke thresholds.

## Tests

- Replaying the same fixture repeatedly yields the same ordered updates and final snapshot.
- Missing/corrupt fixture fields fail clearly without panics.
- Spans never contain prompt text, credentials, paths, attachment bytes, or pairing data.
- Smoke cases cover reduce-stream, item lifecycle, hydration, and burst coalescing.

## Validation

```sh
cargo test --manifest-path shared/rust-bridge/Cargo.toml -p codex-mobile-client
make rust-test
```

## Acceptance Criteria

- The complete Rust-side send-to-update path is traceable by correlation ID.
- Replay correctness is required in CI.
- Smoke budgets are generous, repeatable, and documented as regression alarms rather than claimed production SLOs.
- No user-visible behavior changes.
