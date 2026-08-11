# Task 10 — Stabilize Android tail-follow

## Delegated Mission

`pi-chat-w02-m10-android-tail-follow` · Wave 2 · implementation.

## Objective

Give the Android timeline stable identity and one conflated follow loop that never fights user drag and preserves the viewport across history prepends.

## Files Involved

- `apps/android/app/src/main/java/com/litter/android/ui/conversation/ConversationTimeline.kt` — LazyColumn and follow loop.
- `ConversationScreen.kt` and `TurnGrouping.kt` — stable item model and keys.
- Timeline row composables — stable content types and state ownership.
- `apps/android/app/src/test/` and `src/androidTest/` — policy and scroll tests.

## Changes

- Use durable event/item IDs for keys and bounded stable content types.
- Centralize tail-follow in one `snapshotFlow`/conflated coroutine rather than per-item effects.
- Suspend follow while scrolling/dragging and require an explicit near-tail transition to resume.
- Restore visible key and offset after earlier items are inserted.

## Tests

- Tail-policy unit tests and key-uniqueness assertions.
- Instrumented 1,000-token, drag-away, return-to-tail, keyboard, rotation, and history-prepend scenarios.
- JankStats assertion under the baseline stream fixture.

## Validation

```sh
make android-emulator-fast
cd apps/android && ./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

## Acceptance Criteria

- No per-item scroll-effect fan-out or animated streaming bounce.
- User drag and prepend viewport are preserved.
- Streaming jank is below 5% on the baseline performance-floor device.
