# Task 08 — Validate the combined state wave

## Delegated Mission

`pi-chat-w01-m08-state-wave-validator` · Wave 1 · validation only.

## Objective

Test Missions 05–07 together, resolve contract mismatches through their owning missions, and prove the state-amplification hypothesis is fixed without correctness or first-token regressions.

## Files Involved

- `work/chat-performance/evidence/wave-01/` — combined benchmark and correctness report.
- `GOAL.md` — status and frozen Wave 2 base only.
- No production-code ownership; defects return to Missions 05–07.

## Changes

- Compare Wave 1 against the exact Wave 0 fixtures, devices, and build modes.
- Report reduce/emit, apply/derive, body/recomposition counts, typing latency, CPU, RSS, and first-delta latency.
- Verify replay equality and every secondary-surface cadence/flush contract.
- Issue a pass/block verdict and name any remaining dominant cost.

## Tests

- Combined Rust, iOS, and Android suites.
- Five-run performance comparison at 10/100/500/1,500 items and 60 deltas/s.
- Ten-minute stream memory/CPU soak.

## Validation

```sh
make test
git diff --check origin/main...HEAD
```

## Acceptance Criteria

- All Wave 1 numeric gates in `GOAL.md` pass or the wave is explicitly blocked.
- First-token p95 remains inside the Wave 0 confidence interval.
- The evidence report is reproducible and the Wave 2 base commit is frozen.
