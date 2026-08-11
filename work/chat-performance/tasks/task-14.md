# Task 14 — Prove physical-device acceptance

## Delegated Mission

`pi-chat-w04-m14-device-acceptance` · Wave 4 · validation only.

## Objective

Install the combined build on physical iOS and Android performance-floor devices and produce acceptance evidence for responsiveness, correctness, reconnect, queueing, and long-thread behavior.

## Files Involved

- `work/chat-performance/evidence/wave-04/` — device/build manifest, metrics, screenshots, and verdict.
- `apps/android/docs/qa-matrix.md` — completed parity rows.
- No production-code ownership; defects return to the owning Wave 1–3 mission.

## Changes

- Record device model/OS, app commit/version, Rust profile, server/engine identity, network path, thermal state, and fixture ID.
- Run two-turn, rapid queue, reasoning, tool lifecycle, approval, image, code, long-thread, disconnect/reconnect, resume, and background/foreground scenarios.
- Collect aggregate signposts/Perfetto/JankStats, CPU, RSS, and user-visible recordings without private message content.
- Distinguish source/CI, built package, installed runtime, and any store build.

## Tests

- Five measured runs per latency case per platform after one warm-up.
- Ten-minute sustained stream and 1,500-item open/hydrate test.
- Correctness checklist for final text, item ordering, tool status, approvals, queue order, and session persistence.

## Validation

```sh
make ios-device-fast
make android
./tools/scripts/triage-mobile-feedback.py --last-hours 24
```

## Acceptance Criteria

- Both installed apps pass the complete scenario matrix on physical devices.
- p50/p95/p99, frame health, CPU, and memory are recorded against the GOAL budgets.
- Failures contain a reproducible fixture and return to a named owning mission; they are not patched in the validator.
