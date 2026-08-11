# Task 04 — Establish the baseline and close Wave 0

## Delegated Mission

`pi-chat-w00-m04-baseline-gate` · Wave 0 · validation only.

## Objective

Run the combined observability branch against the agreed fixture/device matrix, publish the first evidence-backed latency baseline, and issue a pass/block verdict for Wave 1.

## Files Involved

- `work/chat-performance/evidence/wave-00/` — aggregate results and trace manifest.
- `work/chat-performance/scope.md` — only evidence-backed budget clarifications.
- `GOAL.md` — registry status and frozen Wave 1 base.
- `apps/android/docs/qa-matrix.md` — measurement-lane coverage.

## Changes

1. Verify Missions 01–03 landed without overlapping ownership or behavior changes.
2. Run 10/100/500/1,500-item, long-response, tool-storm, rapid-send, reconnect, and resume cases at least five times.
3. Report p50/p95/p99, variance, device/build identity, CPU, memory, frame health, and any missing span.
4. Separate simulator/emulator diagnostics from physical-device claims.
5. Mark Wave 0 pass only when replay, trace continuity, privacy, and repeatability gates pass.

## Tests

- Full Rust replay/smoke suite on the combined branch.
- iOS and Android fixture tests and one installed-runtime trace per platform.
- Trace-redaction audit and repeated-run variance check.

## Validation

```sh
make rust-test
make ios-sim
make android
make test
```

## Acceptance Criteria

- A committed baseline identifies the top three costs with evidence and confidence bounds.
- Every provisional budget is accepted, tightened, or flagged as blocked; none is silently relaxed.
- The report names the exact Wave 1 base commit and gives an explicit `PASS` or `BLOCKED` verdict.
