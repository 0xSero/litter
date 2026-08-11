# Task 15 — Integrate, gate, and prepare delivery

## Delegated Mission

`pi-chat-w04-m15-final-integration` · Wave 4 · validation, with edits limited to CI/docs or narrowly scoped defects assigned by Codex.

## Objective

Validate the complete clean-checkout result, make replay and stable regression checks durable in CI, close every workpack task, and prepare the protected-main merge with a rollback map.

## Files Involved

- `.github/workflows/mobile-ci.yml` — deterministic replay and stable smoke gates.
- `apps/android/docs/qa-matrix.md` — final parity record.
- `GOAL.md` and `work/chat-performance/` — statuses, final results, rollback map.
- Production files only for an explicitly assigned integration defect.

## Changes

- Rebase/merge from the frozen Wave 4 base and verify each accepted mission commit and changed-path boundary.
- Run all validation from a clean checkout with generated artifacts rebuilt.
- Gate deterministic correctness and non-flaky relative regressions in CI; keep unstable wall-clock device numbers in nightly/reporting lanes.
- Document feature/commit rollback boundaries and known residual risks.
- Prepare protected-main merge; after merge fetch and prove local `main` and `origin/main` resolve to the same commit.

## Tests

- Full Rust, iOS, and Android test matrix plus bindings regeneration/diff check.
- Combined replay, rapid-send stress, slow-RPC, reconnect, hydration, renderer, scroll, and installed-device acceptance.
- CI rerun/stability check and clean-worktree verification.

## Validation

```sh
make clean
make bindings
make test
git diff --check origin/main...HEAD
git status --short
```

## Acceptance Criteria

- Every task is `complete`, `superseded`, or explicitly `blocked` with evidence.
- Clean-checkout CI and physical-device acceptance pass, and the rollback map is actionable.
- The protected-main merge is ready; after it lands, local `main == origin/main` is proven before declaring the goal complete.
