# Task 00 — Candidate commit disposition matrix

Mission: `pi-chat-w00-m00-reconcile` (Wave 0).
Worktree branch: `codex/pi-chat-w00-m00-reconcile`.
Frozen base: `314271ac` (Merge remote-tracking branch 'origin/main' into
codex/chat-performance-goal), which is `origin/main` at the task's freeze
point plus the chat-performance GOAL/docs commit `0e2b9f76`. The latest
coordinator fetch resolved `origin/main` to `e42ce32386d53e7be5e1e37d0a1bf2e76c137f9d`; that is a later non-overlapping
mobile compatibility cleanup and is **not** part of the frozen Wave 0 base
`314271ac`. Final branch reconciliation against `origin/main` is the
coordinator's job, not this mission's.

GOAL.md's authoritative base `5f651a475a16c93c273501fd370627f826c5e06f` is the
merge-base of `origin/main` and the candidate branch
`codex/local-studio-fidelity-performance`, so the four candidate commits below
are the only commits the candidate branch contributes over `origin/main`.

## Commit-by-commit disposition

| Commit | Subject | Disposition | Integrated as |
|---|---|---|---|
| `025f7f8b` | bridge: preserve Local Studio tool activity | **partial / superseded pending capture** | `cc8efcde` (iOS only); wire normalizer reverted by final lifecycle commit |
| `f1946f45` | sessions: serialize rapid Local Studio follow-ups | **accept** (clean cherry-pick + race-repair) | `f07ce92c` + `09599a9d` |
| `96e77deb` | performance: batch streaming updates at display cadence | **accept** (rewrite + state-machine repair) | `0c957164` + `085d993b` |
| `a4cbf2df` | release: prepare 2.0.0 build 200000260 | **reject** (release-only metadata, out of performance scope) | not integrated |

### `025f7f8b` — partial / superseded pending capture

What the candidate did,two parts):

1. **iOS required-activity preference migration** (`ConversationTimelineView.swift`,
   `SettingsView.swift`, `ToolCallModels.swift`, `ConversationDisplayPreferenceTests.swift`,
   `LitterUITests.swift`): commands and tool results are durable conversation
   record, not optional decoration. Migrate the legacy persisted `hidden` value
   to `collapsed` for those rows via `ConversationDetailDisplayMode.resolveRequiredActivity`,
   and restrict the Commands/Tools pickers to `requiredActivityCases`
   (`expanded`/`collapsed`). This part is independently valid, has its own
   iOS unit/UITest coverage, and is **accepted** (kept on the branch as
   committed in `cc8efcde`).

2. **Legacy lifecycle wire normalization** (`codex-slingshot/src/json_line_wire.rs`):
   normalize older Pi/Local Studio `item/started`/`item/completed` notifications
   at the raw JSONL boundary (insert `0` for a missing `startedAtMs`/`completedAtMs`;
   rewrite an empty-string `commandExecution.cwd` to `/`). The claim was that
   upstream v0.129 made lifecycle timestamps mandatory and `AbsolutePathBuf`
   rejects empty cwd, so strict decode silently drops the whole notification.

   **Disposition: superseded pending capture.** Wave rules require captured
   evidence for compatibility normalization at a wire boundary. The only
   committed tests for this behavior were synthetic inline JSON objects authored
   alongside the normalizer — they prove the normalizer does what it says, not
   that real Pi/Local Studio bridges emit the legacy shape. A synthetic unit-test
   object, prose claim, or inferred old schema is not production evidence.

   **Search performed** (recorded per review 09): grepped the repository and
   Task 00 mission artifacts for a real, already-scrubbed Pi/Local Studio
   `item/started`/`item/completed` JSON-RPC frame demonstrating the legacy
   shape (missing lifecycle timestamp and/or empty-string command cwd).
   Locations/patterns searched:
   - `grep -rliE "item/started|item/completed|startedAtMs|completedAtMs|commandExecution|cwd"` across `*.json`, `*.jsonl`, `*.txt`, `*.md`, `*.rs` excluding `target/`, `node_modules/`, `.git/`, `shared/third_party/`.
   - Fixture directories: `shared/rust-bridge/codex-mobile-client/tests/fixtures/` (only `local-studio-litter-bridge-realtime-v1.json`, a realtime capabilities fixture with no lifecycle frames), `tools/scripts/fixtures/` (only `cargo-dist-0.31.0`).
   - `.pi-missions/task-00/*.jsonl` (Pi session transcripts). These contain `item/started`/`item/completed`/`commandExecution` strings only because the agent ran `git show` on the candidate during reconciliation; they are agent tool-call records, not captured Pi/Local Studio server wire frames.
   - `work/chat-performance/evidence/` (only this disposition doc).

   **Result: no real scrubbed production lifecycle frame exists in the
   repository or Task 00 mission artifacts.**

   **Action taken:** the unproven wire normalizer and its synthetic-only tests
   were removed from `json_line_wire.rs`, restoring the current-base strict
   decode path (`serde_json::from_str::<JSONRPCMessage>(&line)` with no
   `Value` parse/normalize/from_value indirection). `git diff 314271ac --
   shared/rust-bridge/codex-slingshot/src/json_line_wire.rs` is empty — the wire
   file is exactly back to the frozen base. The iOS preference work from
   `cc8efcde` is retained.

   **Concrete follow-up capture task (required before reintroducing any
   normalization):**
   1. Capture actual `item/started` and `item/completed` JSON-RPC frames from
      a real Pi bridge and a real Local Studio bridge over the JSON-line wire
      (not a Codex WebSocket server). Record provider, bridge name, and bridge
      version.
   2. Scrub the frames: remove prompts, attachments, credentials, account
      tokens, private paths, and identifying server/user text. Keep the
      structural shape (method, params, item type, presence/absence of
      `startedAtMs`/`completedAtMs`, `cwd` value and type).
   3. Commit the smallest scrubbed fixture(s) with provenance
      (provider/version, capture date, scrubbing steps) under
      `shared/rust-bridge/codex-mobile-client/tests/fixtures/` or a
      `codex-slingshot` fixture dir.
   4. Replay each fixture through the strict `json_line_wire` decode path and
      record which fields fail strict upstream decode.
   5. Introduce only the normalization the captured fixture proves, bounded to
      the evidenced legacy shape: `cwd` may be normalized only when missing or
      an evidenced empty string; `null`, number, array, and object `cwd` values
      must remain malformed and fail strict decode. Add focused fixture-driven
      tests with the real shape, not synthetic inline JSON.

   This follow-up is out of scope for Task 00's Wave 0 reconciliation and should
   be tracked as a separate capture task by the coordinator.

### `96e77deb` — accept (rewrite + state-machine repair)

What it does: bounds native/FFI streaming publishes to the display cadence.
Candidate `0c957164` added a 16 ms `STREAMING_COALESCE_WINDOW` and
`coalesce_streaming_window`, plus a cadence test.

Compile defect found during reconciliation: the candidate's
`coalesce_streaming_window` called `state.buffered.push_front(next)` where
`next` is `Box<AppStoreUpdateRecord>` (because `merge_app_update` returns
`Err(Box<…>)`). Fixed to `push_front(*next)` matching `coalesce_ready_updates`.

State-machine repair (`085d993b`, reviews 03-05): the candidate unconditionally
sent the first streaming delta through the 16 ms window, delaying an isolated
first delta by up to 16 ms. Replaced with an explicit pacing state machine on
`AppStoreSubscriptionState` (`Option<AppStorePacing>` with active
`(key, item_id)` and absolute `next_flush_at`):

- Non-streaming update: clear pacing, deliver immediately.
- Streaming, different identity / no pacing / past deadline: deliver
  immediately and arm `next_flush_at = now + WINDOW` for that identity.
- Streaming, same identity, `now < next_flush_at`: coalesce until the existing
  absolute deadline, deliver the accumulated update, advance the deadline.
- Passed-deadline flush rearms `next_flush_at = now + WINDOW` so an
  immediately-following same-identity delta coalesces instead of flushing
  again.
- Lag while accumulating: surface the accumulated exact text, set
  `pending_full_resync`; the next receive consumes the flag, clears pacing, and
  returns `FullResync`. Close while accumulating: surface the accumulated text;
  the following receive reports closed normally.

Removed the scheduler-sensitive `elapsed < WINDOW` wall-clock assertion; the
deterministic helper tests are the regression proof.

Focused validation (`app_store::tests`, log
`.pi-missions/task-00/app-store-review-05.log`): 16 passed, 0 failed. First
repaired run compiled the mobile crate into the shared cache in 51.94 s.

### `f1946f45` — accept (clean cherry-pick + race repair)

What it does: serializes rapid Local Studio follow-ups so a second send during
an active turn is queued rather than lost, duplicated, or misordered.
`f07ce92c` added turn-start reservation, queued follow-up drain, reducer/
snapshot queue state, and four queue tests. Applied cleanly onto the reconciled
base.

Race repair (`09599a9d`, reviews 06-08): an old or duplicate terminal event
must be a no-op for a newer in-flight turn.
- `ThreadStatusChanged(Idle|SystemError)`: `upsert_or_merge_thread`'s
  pre-merge status guard preserves `Idle` for any `active_turn_id`
  (pre-existing behavior) and preserves `SystemError` only for a
  `local-queued-turn:` reservation. The event closure preserves
  `active_turn_id`, plan progress, and agent status for a local reservation.
  Normal authoritative active-turn `SystemError` semantics are unchanged.
- `TurnCompleted`: terminal cleanup runs only when the completion is
  authoritative (matches `active_turn_id`, or no active turn for tolerant
  legacy completion). A nonmatching completion is a true no-op: closure
  returns `false` and the caller checks `.unwrap_or(false)`, so no active
  state mutates and no metadata-changed signal fires.

Controlled race test
(`stale_terminal_event_cannot_clear_newer_local_queued_reservation`,
multi-thread tokio): queues two drafts, parks the first `turn/start` after the
reservation installs, applies an old `TurnCompleted` plus duplicate `Idle` and
`SystemError` while parked, attempts a second drain (sends nothing), asserts
the reservation stays authoritative, status stays `Active`, one draft remains
queued, then releases the first request and asserts it resolves to the returned
turn id with no duplicate send. The existing
`failed_queued_follow_up_dispatch_restores_message_without_a_ghost_turn` test
still proves a failed claimed request restores its draft at the front and
removes the optimistic overlay.

Focused validation (`mobile_client::store_listener::tests`, log
`.pi-missions/task-00/store-listener-review-07.log`): 6 passed, 0 failed.
First re-patched run (after the coordinator restored/reapplied the submodule)
rebuilt upstream Codex and the mobile crate in 2m 48s; the subsequent
correctly cached mobile-only run compiled in 1m 03s. The final wave policy is
patch-once/restore-once: restore/reapply invalidates upstream fingerprints and
forces a full rebuild, so the submodule is kept patched through all Rust
validation and restored once at the end of Task 00.

### `a4cbf2df` — reject (release-only metadata, out of scope)

Bumps iOS `CURRENT_PROJECT_VERSION` 200000254 → 200000260, Android
`versionCode` 200000254 → 200000260, rewrites iOS release notes and
`docs/releases/testflight-whats-new.md`, and edits the generated
`apps/ios/Litter.xcodeproj/project.pbxproj` version fields. It is release
submission metadata, not chat performance behavior. Per task-00 ("Exclude
release-only metadata unless it is independently required by the user") and
GOAL.md non-goals. The user has not authorized a release bump in this mission.
Current `origin/main` version fields remain `200000254` and are unchanged on
this branch. Rejecting here does not lose any performance work.

## Frozen Wave 0 base

Base: `314271ac`. Integrated candidate stack (this branch,
`codex/pi-chat-w00-m00-reconcile`, head after Task 00):

1. `cc8efcde` bridge: preserve Local Studio tool activity (iOS preference work
   only; wire normalizer later reverted)
2. `0c957164` performance: batch streaming updates at display cadence
   (reconciled, with unbox fix)
3. `f07ce92c` sessions: serialize rapid Local Studio follow-ups (reconciled)
4. `c8f21307` docs(chat-perf): record Wave 0 candidate disposition matrix
5. `085d993b` performance: repair cadence state machine (first-delta, rearm,
   lag recovery)
6. `09599a9d` sessions: preserve local reservation against stale terminal
   events
7. (final lifecycle/docs follow-up commit) bridge: revert unproven lifecycle
   wire normalization; docs: update Task 00 disposition

Not integrated: `a4cbf2df` (release metadata, rejected).

Submodule: `shared/third_party/codex` is pinned at
`13595c36e218fcbd13df118eeadf00d4eb0e6d31` (unchanged from `origin/main`).
No submodule gitlink is staged or committed on this branch. Patches are applied
to the submodule working tree only for the duration of Rust validation via
`./apps/ios/scripts/sync-codex.sh --preserve-current` and are restored to
the pinned clean checkout at the end of Task 00.

## Build/test economy

Cold full builds in this worktree are expensive (the initial baseline
`cargo test --no-run` for `-p codex-mobile-client -p codex-slingshot` took
16 m 27 s). To avoid repeated cold builds, validation uses the shared
launcher-provided `CARGO_TARGET_DIR=/Users/sero/ai/projects/litter/.git/codex-cache/chat-performance/cargo-target`
(a 25 GB shared cache moved in by the coordinator). All post-baseline test
commands resolve against that cache.

Final full-crate suites (run once each, early in the mission, before the
review-driven repairs): `cargo test -p codex-mobile-client` → lib 778
passed/7 ignored, cloud_sync 6, pair 3, repro_priority 1, doc-tests 1 (compile
1 m 28 s); `cargo test -p codex-slingshot` → lib 14 passed, doc-tests 0
(compile 2.15 s). These suites are not re-run after the review-driven repairs;
the repairs are covered by the focused filters below, and the coordinator
instructed not to rerun unchanged full suites.

Focused validation after repairs (shared cache, patched submodule):
- `cargo test -p codex-mobile-client --lib app_store::tests` → 16 passed
  (log `.pi-missions/task-00/app-store-review-05.log`; first repaired compile
  51.94 s).
- `cargo test -p codex-mobile-client --lib mobile_client::store_listener::tests`
  → 6 passed (log `.pi-missions/task-00/store-listener-review-07.log`; final
  cached mobile-only compile 1 m 03s).
- Lifecycle wire: because the unproven Rust behavior was removed back to the
  known base, no cargo command was run solely to prove its absence. `git diff
  314271ac -- shared/rust-bridge/codex-slingshot/src/json_line_wire.rs` is
  empty, confirming the exact reversal.

## Acceptance criteria mapping

- "Every candidate commit has a documented disposition and evidence." → the
  matrix above; accepts have focused test results; the partial/superseded
  lifecycle disposition has a concrete capture task; the reject has a reason.
- "The frozen Wave 0 base is clean, pushed, reproducible, and contains no
  accidental release metadata or submodule edits." → base `314271ac` plus the
  reconciled/repair commits; no release metadata (version fields unchanged at
  200000254); submodule gitlink unchanged at `13595c36e` and not
  staged/committed. (Push is coordinator-controlled; this mission does not
  push.)
- "Accepted queue and pacing behavior has focused tests; rejected work has a
  concrete replacement task." → queue: controlled race test + failure-restore
  test under `mobile_client::store_listener::tests`; pacing: 16 tests under
  `app_store::tests`; rejected release metadata needs no performance
  replacement; superseded lifecycle normalization has the capture task above.

## Surfaces not proven by this mission

- Push/reproducibility on `origin` is coordinator-controlled.
- iOS UITest/unit execution (`xcodebuild test`) is deferred to the Wave 0
  combined validator (M04) and the normal iOS lane. The iOS preference
  migration's own tests are the candidate's already-reviewed tests, retained
  unchanged.
- Android build/test: no Android source changed; Android has no equivalent
  display-mode preference (verified by grep), so there is no Android parity
  work to validate here.
- Cadence/queue behavior is proven at the Rust unit level only, not yet under
  installed-runtime measurement (Wave 0 baselines M01–M03, device acceptance
  Wave 4 M14).
- Lifecycle wire normalization is **not** proven against production frames;
  it is reverted pending the capture task above.

## Remaining risks

- The tolerant legacy `TurnCompleted` path (`active_turn_id.is_none()` still
  accepts any completion) is preserved to avoid breaking existing events/tests
  that arrive after the store cleared the turn. If a future event sequence
  relies on a stale completion clearing a none-active turn to Idle, that still
  happens (no regression).
- The 16 ms coalesce window is a fixed display-cadence constant; Wave 1 may
  need to parameterize or gate the first-token fast path separately.
- Removing the lifecycle normalizer restores the pre-candidate behavior: if a
  real older Pi/Local Studio bridge emits a missing timestamp or empty cwd,
  strict decode will drop that notification until the capture task reintroduces
  evidenced normalization. This is the honest state: do not ship unproven
  wire normalization.
