# Task 00 — Candidate commit disposition matrix

Mission: `pi-chat-w00-m00-reconcile` (Wave 0).
Worktree branch: `codex/pi-chat-w00-m00-reconcile` (frozen base `314271ac`, itself `origin/main` at `2843dcf3` plus the GOAL.md/docs commit `0e2b9f76`).
Candidate branch: `codex/local-studio-fidelity-performance`.
Authoritative base recorded in GOAL.md: `origin/main` at `5f651a475a16c93c273501fd370627f826c5e06f`. The candidate branch's merge-base with `origin/main` is exactly `5f651a4`, so the four candidate commits are the only commits the candidate branch contributes over `origin/main`.

## Commit-by-commit disposition

| Commit | Subject | Disposition | Integrated as |
|---|---|---|---|
| `025f7f8b` | bridge: preserve Local Studio tool activity | **accept** (rewrite, conflict resolved) | `cc8efcde` |
| `f1946f45` | sessions: serialize rapid Local Studio follow-ups | **accept** (clean cherry-pick) | `f07ce92c` |
| `96e77deb` | performance: batch streaming updates at display cadence | **accept** (rewrite, one-line compile fix) | `0c957164` |
| `a4cbf2df` | release: prepare 2.0.0 build 200000260 | **reject** (release-only metadata, out of performance scope) | not integrated |

### `025f7f8b` — accept (rewrite)

What it does:
- `shared/rust-bridge/codex-slingshot/src/json_line_wire.rs`: normalize legacy non-Codex (Pi/Local Studio) item lifecycle notifications at the raw JSONL boundary. v0.129 of the upstream app-server schema made `startedAtMs`/`completedAtMs` mandatory; older bridges emit otherwise-valid `item/started`/`item/completed` notifications without them, and `RemoteAppServerClient` strict-decodes and silently drops the entire notification (including tool calls/results). The normalizer inserts `0` for a missing timestamp and rewrites an empty `commandExecution.cwd` to `/` (AbsolutePathBuf rejects empty cwd). Normalization happens before `serde_json::from_value::<JSONRPCMessage>`, so strict upstream decode succeeds. Explicit timestamps are never overwritten. Three unit tests cover the legacy timestamp fill, explicit-timestamp preservation, and the empty-cwd command case.
- iOS (`ConversationTimelineView.swift`, `SettingsView.swift`, `ToolCallModels.swift`, tests): commands and tool results are durable conversation record, not optional decoration. Migrate the legacy persisted `hidden` value to `collapsed` for those rows via `ConversationDetailDisplayMode.resolveRequiredActivity`, and restrict the Commands/Tools pickers to `requiredActivityCases` (`expanded`/`collapsed`). A UITest is retargeted to assert tool/command activity stays visible under the legacy `hidden` preference.

Conflict and rewrite: the candidate's `next_message` was written in the pre-`async fn` `impl Future` form. The current base uses `async fn next_message` (the trait was already migrated). Cherry-pick conflicted in `json_line_wire.rs`. Resolution: kept the current `async fn` signature and ported the normalization logic (parse to `serde_json::Value`, normalize, `from_value`) into it. The candidate's `impl Future` wrapper is no longer needed on this base and was dropped. No behavior change versus the candidate's intent.

Rust-first placement: the lifecycle normalization is wire-boundary work and lives in `codex-slingshot`, not in Swift/Kotlin. Correct placement.

Mobile parity: the iOS display-mode migration is iOS-only persisted-preference cleanup. Android has no equivalent `ConversationDetailDisplayMode` / command-tool `hidden` preference (verified: no `commandDisplayMode`/`toolDisplayMode`/`resolveRequiredActivity`/`requiredActivityCases` symbols exist under `apps/android/`). Android's conversation rendering has no `hidden` mode for command/tool rows, so there is no parity gap to close. This is truly platform-specific (iOS-only persisted preference migration), documented here per the drift guardrails.

Evidence:
- `cargo test -p codex-slingshot --lib json_line_wire` → 3 passed, 0 failed (lifecycle timestamp fill, explicit-timestamp preservation, empty-cwd command survival).

### `96e77deb` — accept (rewrite, one-line compile fix)

What it does: bounds native/FFI streaming publishes to the display cadence. Adds `STREAMING_COALESCE_WINDOW = 16 ms` and `coalesce_streaming_window`, which collects contiguous `ThreadStreamingDelta` updates for one frame window before handing the merged delta to the existing `coalesce_ready_updates` drain. Non-streaming updates and merge-boundary collisions short-circuit immediately (first-token / first-non-streaming immediacy preserved). One test asserts 48 deltas at 2 ms spacing batch into ≤ 12 native updates while preserving exact text.

Compile defect found during reconciliation: the candidate's `coalesce_streaming_window` called `state.buffered.push_front(next)` where `next` is `Box<AppStoreUpdateRecord>` (because `merge_app_update` returns `Err(Box<AppStoreUpdateRecord>)`). The sibling `coalesce_ready_updates` correctly unboxes with `*next`. On this base the candidate does not compile. Fix: `state.buffered.push_front(*next)`. This is a latent defect in the candidate that the candidate's own base apparently did not surface (different `merge_app_update` return shape at that time). The fix is the minimal one-line unbox; no behavior change versus the candidate's intent.

Rust-first placement: FFI coalescing is shared Rust. Correct.

Evidence:
- `cargo test -p codex-mobile-client --lib app_store::tests` → 10 passed, 0 failed (includes the new cadence test and the pre-existing coalesce/boundary/resync tests, confirming no regression in the shared coalesce path).

### `f1946f45` — accept (clean cherry-pick)

What it does: serializes rapid Local Studio follow-ups so a second send during an active turn is queued rather than lost, duplicated, or misordered. Adds turn-start reservation in `mobile_client/mod.rs`, a queued follow-up drain in `store_listener.rs`, queue state in `store/reducer.rs` and `store/snapshot.rs`, a `thread_projection.rs` hook, and four tests under `mobile_client::tests`: `active_status_without_turn_id_queues_instead_of_losing_the_message`, `turn_start_response_reserves_thread_before_a_rapid_second_send`, `live_local_studio_resume_preserves_unique_command_results`, `live_local_studio_rapid_second_send_runs_once_after_tool_turn`.

Cherry-pick applied cleanly onto the reconciled base (`025f7f8b` + `96e77deb`); no conflict, no rewrite.

Rust-first placement: queue/reservation/reducer logic is shared Rust. Correct. This directly satisfies GOAL.md success contract #4 (rapid double-send yields one active turn and one queued follow-up) at the unit level; device-level proof belongs to Wave 4.

Evidence:
- `cargo test -p codex-mobile-client --lib mobile_client::tests` → 41 passed, 2 ignored, 0 failed (includes the 4 new queue tests).
- `cargo test -p codex-mobile-client --lib store::` → 98 passed, 0 failed (reducer/snapshot/voice/app_store, no regression from the reducer/snapshot edits).

### `a4cbf2df` — reject (release-only metadata, out of scope)

What it does: bumps iOS `CURRENT_PROJECT_VERSION` 200000254 → 200000260, Android `versionCode` 200000254 → 200000260, rewrites iOS release notes and `docs/releases/testflight-whats-new.md`, and edits the generated `apps/ios/Litter.xcodeproj/project.pbxproj` version fields. It is release submission metadata, not chat performance behavior.

Disposition: reject for Wave 0. Per task-00 ("Exclude release-only metadata unless it is independently required by the user") and GOAL.md non-goals ("No store publication, release submission, authentication, signing, or payment without the user at the protected boundary"). The user has not authorized a release bump in this mission. Rejecting here does not lose any performance work: the three behavioral commits above are integrated without it.

Replacement/follow-up: none required for performance. If a future release wants the candidate's release-notes wording, that is a separate user-authorized release task. The current `origin/main` version fields remain `200000254` and are unchanged on this branch.

## Frozen Wave 0 base

Base: `314271ac` (Merge remote-tracking branch 'origin/main' into codex/chat-performance-goal), which is `origin/main` (`2843dcf3`) plus the chat-performance GOAL/scope/rules/docs commit `0e2b9f76`. `origin/main` resolves to `2843dcf3`; the goal base `5f651a4` is the merge-base of `origin/main` and the candidate branch.

Integrated candidate stack (this branch, `codex/pi-chat-w00-m00-reconcile`):
1. `cc8efcde` bridge: preserve Local Studio tool activity (reconciled onto async-fn wire)
2. `0c957164` performance: batch streaming updates at display cadence (reconciled)
3. `f07ce92c` sessions: serialize rapid Local Studio follow-ups (reconciled)

Not integrated: `a4cbf2df` (release metadata, rejected).

Submodule: `shared/third_party/codex` is pinned at `13595c36e218fcbd13df118eeadf00d4eb0e6d31` (unchanged from `origin/main`). No submodule gitlink is staged or committed on this branch. Patches are applied to the submodule working tree only for the duration of Rust validation via `./apps/ios/scripts/sync-codex.sh --preserve-current` and are not committed.

## Build/test economy

Cold full builds in this worktree are expensive (the initial `cargo test --no-run` for `-p codex-mobile-client -p codex-slingshot` took 16 m 27 s). To avoid repeated cold builds, validation uses the shared launcher-provided `CARGO_TARGET_DIR=/Users/sero/ai/projects/litter/.git/codex-cache/chat-performance/cargo-target` (a 25 GB shared cache moved in by the coordinator). All test commands below resolve against that cache.

Commands actually completed (in order):

1. `git fetch --all --prune` — refreshed refs; only one stale remote branch pruned.
2. `git log --left-right --cherry-pick --oneline origin/main...codex/local-studio-fidelity-performance` — confirmed the four candidate commits are the only candidate-side commits over `origin/main` (merge-base `5f651a4`).
3. `git show --stat` for each of the four commits — recorded changed paths.
4. Cherry-pick dry runs in a throwaway `/tmp/cp-test` shared clone — identified the `025f7f8b` conflict in `json_line_wire.rs` and confirmed `96e77deb`/`f1946f45` apply cleanly.
5. `./apps/ios/scripts/sync-codex.sh --preserve-current` — initialized the codex submodule and applied the pinned patch set so the Rust crates compile.
6. Baseline (before any candidate edit): `cargo test --manifest-path shared/rust-bridge/Cargo.toml -p codex-mobile-client -p codex-slingshot` — full suite green: codex-mobile-client lib 772 passed/5 ignored, integration tests (cloud_sync 6, pair 3, repro_priority 1) green, codex-slingshot lib 11 passed, doc-tests green. (This baseline ran against the default local target dir before the shared cache was wired; it is valid evidence that the base is green and is not repeated.)
7. After reconciling `025f7f8b`: `cargo test -p codex-slingshot --lib json_line_wire` (shared cache, 2.43 s incremental) → 3 passed.
8. After reconciling `96e77deb` (+ unbox fix): `cargo test -p codex-mobile-client --lib app_store::tests::app_store_subscription_batches_interleaved_streaming_at_display_cadence` (52.34 s, first mobile-client compile into the shared cache) → 1 passed. Then `cargo test -p codex-mobile-client --lib app_store::tests` (2.01 s incremental) → 10 passed.
9. After cherry-picking `f1946f45`: `cargo test -p codex-mobile-client --lib mobile_client::tests` (2 s incremental) → 41 passed/2 ignored. Then `cargo test -p codex-mobile-client --lib store::` (incremental) → 98 passed.

Full-crate final suites: run at most once each, at the end, per the coordinator's instruction. Results recorded in the handoff VALIDATION section. If a full suite times out, the last completed phase is recorded and the suite is not automatically retried.

## Acceptance criteria mapping

- "Every candidate commit has a documented disposition and evidence." → the matrix above; each accept has a focused test result, the reject has a concrete reason and follow-up.
- "The frozen Wave 0 base is clean, pushed, reproducible, and contains no accidental release metadata or submodule edits." → base is `314271ac` + three reconciled commits; no release metadata; submodule gitlink unchanged at `13595c36e` and not staged/committed. (Push is coordinator-controlled; this mission does not push.)
- "Accepted queue and pacing behavior has focused tests; rejected work has a concrete replacement task." → queue: 4 tests under `mobile_client::tests`; pacing: 1 cadence test under `app_store::tests` plus the pre-existing coalesce tests; rejected release metadata needs no replacement task for performance.
