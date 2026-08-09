# Task 07 — Isolate Android streaming state

## Session

`chat-w01-s07-android-state-isolation` · Wave 1 · implementation.

## Objective

Consume the narrow Rust stream contract through scoped StateFlows so only active transcript consumers recompose, blocking work stays off main, and streamed text growth is linear.

## Files Involved

- `apps/android/app/src/main/java/com/litter/android/state/AppModel.kt` — flow ownership and JNI/store application.
- `apps/android/app/src/main/java/com/litter/android/ui/conversation/ConversationScreen.kt` — scoped collection.
- `ComposerBar.kt`, header/sidebar, approval, and home-summary consumers identified by Session 03.
- `TurnGrouping.kt` and `SelectableConversationText.kt` — render-ready derivation/text accumulation.
- `apps/android/app/src/test/` and `src/androidTest/` — flow/recomposition tests.

## Changes

- Split transcript, composer, header/sidebar, connection, and secondary summary flows.
- Use immutable, distinct projections with stable equality and lifecycle-aware collection.
- Remove main-thread blocking JNI/store calls and repeated full-string concatenation.
- Flush completion, approval, error, and queue transitions immediately.

## Tests

- Turbine/flow tests proving unrelated collectors receive no token update.
- Linear text-growth and 1,500-item projection regression tests.
- Instrumented composer typing and recomposition-count tests during sustained streaming.
- Completion/approval/connection freshness tests.

## Validation

```sh
make android-emulator-fast
cd apps/android && ./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

## Acceptance Criteria

- Only active transcript consumers recompose for token batches.
- No blocking shared-client call runs on the main thread.
- Apply/derive p95 is at or below 4 ms and typing p95 is at or below 16 ms.
