# Mobile: Plan Mode State Is Lost After App Crash/Relaunch

Issue target: https://github.com/dnakov/litter

Created issue: https://github.com/dnakov/litter/issues/100

Fix branch: https://github.com/julianpistorius/litter/tree/fix/persist-thread-plan-mode

Suggested issue title:

```text
Mobile: plan mode state is lost after app crash/relaunch
```

## Summary

Mobile threads can lose their local Plan-mode state after app crash or process restart. The conversation can still be in Plan mode on the Codex side, but Litter rehydrates the thread as Default mode.

Result: when the user types "implement this" or similar after relaunch, Codex responds that it is in planning mode and cannot implement. The user has to toggle Plan mode in Litter and send another message before the app catches up and offers the implement-plan affordance.

## Reproduction

1. Connect Litter to a Codex server/desktop IPC session.
2. Open a thread.
3. Switch the thread to Plan mode.
4. Ask Codex for a plan and wait for a proposed plan plus the implement prompt.
5. Kill the app process:

```bash
xcrun simctl terminate booted com.sigkitten.litter
adb -e shell am force-stop com.sigkitten.litter.android
```

6. Relaunch Litter, reconnect, and open the same thread.
7. Type something intended to implement the plan.

Actual: Codex reports it is in planning mode and cannot implement. The app does not reliably show the implement-plan prompt.

Workaround: Toggle Plan mode in the app, send another message, then Codex says it is already in Plan mode and the app eventually asks whether to implement the plan.

Expected: Litter restores the thread's Plan mode after app relaunch and shows the implement-plan affordance when the loaded history contains an unimplemented proposed plan.

## Root Cause

The app server thread snapshots do not currently include the local collaboration mode as thread metadata.

Relevant code paths:

- `ThreadSnapshot::from_info` defaults `collaboration_mode` to `AppModeKind::Default`.
- Hydration from upstream `thread/read`, `thread/resume`, `thread/fork`, and paged turns reconstructs items/model/runtime state, but does not restore Plan mode from durable local state.
- `MobileClient::start_turn` injects `collaboration_mode: Plan` only when the local `ThreadSnapshot` is already Plan.
- The implement prompt is transient: live `TurnCompleted` sets `pending_plan_implementation_turn_id`, but cold hydration previously did not reconstruct that prompt from the loaded proposed-plan item.

So after app process death, the new store has no memory that the thread was Plan, and the next `turn/start` goes out without a Plan collaboration-mode override.

## Fixed Branch

Branch: `fix/persist-thread-plan-mode`

Fork link: https://github.com/julianpistorius/litter/tree/fix/persist-thread-plan-mode

Fix outline:

- Add Rust-owned `thread_modes.json` under the existing mobile preferences directory.
- Persist only non-default per-thread collaboration modes.
- Register the preferences directory from iOS and Android startup.
- Persist Plan mode on explicit mode change and when a received `ThreadItem::Plan` auto-detects planning mode.
- Remove the persisted entry when `implement_plan` switches back to Default.
- Apply persisted mode during thread list/read/resume/fork/rollback/turn-page reconciliation and as a last check before `turn/start`.
- Restore the implement-plan prompt from hydrated history when a Plan-mode thread contains a latest proposed-plan item with no later user turn.

## Tests

Added tests cover:

- persisted Plan mode round-trips from disk;
- setting Default removes persisted Plan mode;
- auto-detected `ThreadItem::Plan` persists Plan mode;
- restored Plan mode causes next `turn/start` to include `collaboration_mode: Plan`;
- hydrated proposed plan restores the implement prompt;
- dismissed prompt does not reappear in the same runtime;
- a later user turn suppresses restored implement prompt.

Local verification:

- `rustfmt --edition 2024 --check ...` passed for changed Rust files.
- `git diff --check` passed.
- `cargo test -p codex-mobile-client --lib thread_modes` was attempted after initializing `shared/third_party/codex`, but the first-time workspace build failed with `No space left on device` after filling the Rust target directory. `cargo clean` removed the generated target artifacts and recovered 4.1 GiB.

## Follow-Ups

Personal TODOs:

- Learn how to deploy Litter iOS/Android apps on my own phone.
- Investigate porting Litter to PWA with WASM.
