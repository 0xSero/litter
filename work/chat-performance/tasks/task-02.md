# Task 02 — Add iOS send-to-frame observability

## Session

`chat-w00-s02-ios-observability` · Wave 0 · implementation.

## Objective

Measure iOS send tap, Rust local overlay, first store update, projection, renderer delivery, first glyph, and frame commit using a repeatable Release-profile lane.

## Files Involved

- `apps/ios/Sources/Litter/Models/AppModel.swift` — subscription and update application.
- `apps/ios/Sources/Litter/Views/ConversationScreenModel.swift` — projection/derivation.
- `apps/ios/Sources/Litter/Views/ConversationView.swift` and `MessageBubbleView.swift` — send and visible render milestones.
- New `apps/ios/Sources/Litter/Models/PerfSignposts.swift` — typed signpost helper.
- `apps/ios/Tests/` and `apps/ios/scripts/run-device.sh` — fixture metric and xctrace lane.

## Changes

- Add privacy-safe `OSSignposter` intervals keyed by correlation ID.
- Mark send tap, local echo observation, first delta, apply completion, projection completion, renderer append, and first visible glyph/frame.
- Add counters for body/projection updates and tail-scroll requests.
- Make the device command prove Release Swift and `mobile-release` Rust rather than whichever fast staticlib was last built.

## Tests

- Signpost interval pairing and correlation-ID propagation.
- Fixture-harness performance test using recorded updates.
- Logging redaction test for prompt and attachment content.

## Validation

```sh
make bindings
make ios-sim
xcodebuild test -project apps/ios/Litter.xcodeproj -scheme Litter -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Acceptance Criteria

- Instruments shows an unbroken send-to-frame timeline.
- The same fixture produces repeatable summary JSON/Markdown without committing raw private traces.
- Fast-lane and release-profile artifacts cannot be confused in the baseline script.
- No user-visible behavior changes.
