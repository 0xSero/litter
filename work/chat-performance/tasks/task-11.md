# Task 11 — Optimize rendering only when profiles trigger it

## Delegated Mission

`pi-chat-w02-m11-profiled-rendering` · Wave 2 · evidence-gated implementation.

## Objective

Use Wave 1/2 traces to decide whether Markdown, code, math, image, reasoning, or tool-row rendering remains material; make only the smallest measured cache or incremental-render change, or record a no-op verdict.

## Files Involved

- `apps/ios/Sources/Litter/Views/MessageBubbleView.swift` and renderer helpers.
- `apps/android/app/src/main/java/com/litter/android/ui/conversation/SelectableConversationText.kt` and row renderers.
- Platform cache helpers and renderer tests, only if the 10% admission threshold is met.
- `work/chat-performance/evidence/wave-02/rendering-decision.md`.

## Changes

1. Attribute main-thread time by content type after Missions 09–10.
2. If parsing/rendering is below 10%, change no production code and document the result.
3. If triggered, key bounded caches by immutable content hash plus theme/width/options; never cache sensitive content to disk.
4. Keep streaming text incremental where the renderer supports it and flush exact final content on settle.

## Tests

- Cache hit/miss, eviction, theme/width invalidation, and memory-bound tests when a cache is added.
- Golden rendering for Markdown, long code, math, images, reasoning, tool rows, links, and selection.
- Ten-minute memory soak and first/final content correctness.

## Validation

```sh
make test
```

## Acceptance Criteria

- The committed decision cites profiles and the admission threshold.
- Any implementation reduces the measured cost by at least 20% without violating memory or correctness ceilings.
- A no-op verdict is considered complete when rendering is not a material cost.
