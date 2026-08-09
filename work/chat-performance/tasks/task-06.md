# Task 06 — Isolate iOS streaming observation

## Session

`chat-w01-s06-ios-state-isolation` · Wave 1 · implementation.

## Objective

Consume the narrow Rust stream contract so active transcript updates invalidate only the necessary iOS conversation projection, while composer input and secondary surfaces remain responsive and correct.

## Files Involved

- `apps/ios/Sources/Litter/Models/AppModel.swift` — snapshot/update routing.
- `apps/ios/Sources/Litter/Views/ConversationScreenModel.swift` — active-thread projection.
- `apps/ios/Sources/Litter/Views/ConversationView.swift` — observation boundaries.
- iOS watch/widget, PiP, home-summary, and approval projection files discovered during Session 02.
- `apps/ios/Tests/LitterTests/` — invalidation and freshness tests.

## Changes

- Split high-frequency transcript observation from low-frequency global/session summaries.
- Move derivation off the main actor where safe, publishing only immutable render-ready deltas on the main actor.
- Coalesce watch/widget/PiP/home summaries at a documented cadence and flush on settle or approval.
- Keep composer draft state independent from streaming transcript updates.

## Tests

- Body/projection update-count assertions for active and unrelated screens.
- Composer typing during 60 deltas/s and completion-flush tests.
- Watch/widget/PiP/home/approval freshness tests.
- Fixture replay UI snapshot equivalence.

## Validation

```sh
make ios-sim-fast
xcodebuild test -project apps/ios/Litter.xcodeproj -scheme Litter -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Acceptance Criteria

- No whole-application observation invalidation per token.
- Keystroke-to-glyph p95 stays at or below 16 ms while streaming.
- Platform apply/derive p95 is at or below 4 ms, with secondary surfaces correct at their declared cadence.
