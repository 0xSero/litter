# Task 00 — Reconcile existing performance and queue repairs

## Delegated Mission

`pi-chat-w00-m00-reconcile` · Wave 0 · investigate first, then edit only when the disposition is evidence-backed.

## Objective

Compare `025f7f8b`, `f1946f45`, `96e77deb`, and `a4cbf2df` with current `origin/main`; produce an accept/rewrite/supersede/reject matrix and create the frozen Wave 0 integration base without duplicating or silently dropping work.

## Files Involved

- `shared/rust-bridge/codex-mobile-client/src/ffi/app_store.rs` — candidate display-cadence batching.
- `shared/rust-bridge/codex-mobile-client/src/mobile_client/mod.rs` — turn start and queue decision path.
- `shared/rust-bridge/codex-mobile-client/src/mobile_client/store_listener.rs` — queued follow-up drain.
- `shared/rust-bridge/codex-mobile-client/src/store/reducer.rs` and `snapshot.rs` — reservation and queue state.
- `shared/rust-bridge/codex-slingshot/src/json_line_wire.rs` — lifecycle compatibility.
- Release metadata files changed by `a4cbf2df` — explicitly separate from performance scope.

## Changes

1. Fetch all refs and record base/head commits and dirty-worktree boundaries.
2. Review each candidate commit independently, including tests and current upstream compatibility.
3. Run focused Rust tests at each accepted commit and on the combined candidate stack.
4. Exclude release-only metadata unless it is independently required by the user.
5. Create the frozen Wave 0 base and a disposition document under `work/chat-performance/evidence/`.

## Tests

- Queue concurrency and restore-order tests from the candidate stack.
- Subscription pacing/coalescing tests, including first-delta immediacy.
- JSONL lifecycle fixture tests for missing timestamps and strict downstream decode.
- Full `cargo test -p codex-mobile-client` and `cargo test -p codex-slingshot`.

## Validation

```sh
git log --left-right --cherry-pick --oneline origin/main...codex/local-studio-fidelity-performance
cargo test --manifest-path shared/rust-bridge/Cargo.toml -p codex-mobile-client
cargo test --manifest-path shared/rust-bridge/Cargo.toml -p codex-slingshot
```

## Acceptance Criteria

- Every candidate commit has a documented disposition and evidence.
- The frozen Wave 0 base is clean, pushed, reproducible, and contains no accidental release metadata or submodule edits.
- Accepted queue and pacing behavior has focused tests; rejected work has a concrete replacement task.
