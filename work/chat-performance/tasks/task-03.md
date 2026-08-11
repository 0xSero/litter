# Task 03 — Add Android send-to-frame observability

## Delegated Mission

`pi-chat-w00-m03-android-observability` · Wave 0 · implementation.

## Objective

Measure Android send tap, JNI/store work, StateFlow publication, transcript derivation, render, and frame health with Perfetto-compatible traces and JankStats.

## Files Involved

- `apps/android/app/src/main/java/com/litter/android/state/AppModel.kt` — store subscription and update application.
- `ui/conversation/ComposerBar.kt`, `ConversationScreen.kt`, `ConversationTimeline.kt`, `TurnGrouping.kt`, and `SelectableConversationText.kt` — send, derive, render, and scroll stages.
- `apps/android/app/build.gradle.kts` — tracing/JankStats dependencies and Compose metrics configuration.
- `apps/android/app/src/test/` and `src/androidTest/` — trace helper and fixture coverage.

## Changes

- Add privacy-safe trace sections and correlation IDs across coroutine/JNI boundaries.
- Record apply/derive/parse/scroll durations, recomposition counters, janky/frozen frames, and first visible glyph.
- Emit small aggregate baseline artifacts while keeping raw Perfetto traces access-controlled.
- Enable Compose compiler metrics for the baseline lane.

## Tests

- Trace helper pairing and redaction.
- JVM fixture replay through state/projection code.
- Instrumented smoke covering first glyph and JankStats attachment.

## Validation

```sh
make android
cd apps/android && ./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

## Acceptance Criteria

- Perfetto shows an unbroken send-to-frame timeline with Rust/JNI correlation.
- JankStats and Compose metrics are collected without changing production behavior.
- Baseline summaries are repeatable and contain no user content or secrets.
