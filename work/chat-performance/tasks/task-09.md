# Task 09 — Stabilize iOS tail-follow

## Session

`chat-w02-s09-ios-tail-follow` · Wave 2 · implementation.

## Objective

Replace render-to-scroll feedback with one settled, non-animated tail-follow path that respects user drag and preserves viewport position when older turns load.

## Files Involved

- `apps/ios/Sources/Litter/Views/ConversationView.swift` — scroll container and follow policy.
- `apps/ios/Sources/Litter/Views/MessageBubbleView.swift` — row identity/geometry notifications.
- `ConversationScreenModel.swift` — render epoch and tail state if required.
- `apps/ios/Tests/LitterTests/` — deterministic policy tests.

## Changes

- Define explicit `followingTail`, `userDetached`, `loadingHistory`, and `settling` states.
- Conflate streaming changes into at most one non-animated scroll request per display cadence.
- Suppress auto-follow during drag and restore only through an explicit near-tail/user action rule.
- Anchor before prepending history and restore the same visible item/offset afterward.
- Retain existing `AnyView` row dispatch unless a trace proves it is now harmful.

## Tests

- Pure tail-policy state-machine tests.
- 1,000-token stream with no animated bounce or scroll loop.
- Drag-away, return-to-tail, rotation, keyboard, and history-prepend UI tests.

## Validation

```sh
make ios-sim-fast
xcodebuild test -project apps/ios/Litter.xcodeproj -scheme Litter -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Acceptance Criteria

- Streaming produces at most one conflated tail request per frame and no continuous animation.
- User drag is never overridden.
- Loading earlier turns preserves the viewport and iOS hitch time remains below 5 ms/s.
