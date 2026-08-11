# Goal: Make Litter chat feel immediate

## Mission

Make Litter chat measurably low-latency, responsive, and robust on iOS and Android without duplicating shared behavior across Swift and Kotlin. The work is executed in waves. Every wave is composed of named delegated Pi missions with explicit ownership, dependencies, deliverables, and acceptance gates.

This file is the orchestration source of truth. Detailed mission briefs live in [`work/chat-performance/tasks/`](work/chat-performance/tasks/).

## Ground truth

- Authoritative base at goal creation: `origin/main` at `5f651a475a16c93c273501fd370627f826c5e06f`.
- Candidate branch `codex/local-studio-fidelity-performance` contains four commits not on `origin/main`:
  - `025f7f8b` — Local Studio tool lifecycle compatibility.
  - `f1946f45` — rapid-follow-up serialization and queue tests.
  - `96e77deb` — display-cadence streaming batching.
  - `a4cbf2df` — 2.0 release metadata.
- Wave 0 must disposition these commits before new implementation. Do not reimplement or silently discard them.
- The original checkout may contain dirty submodules and unrelated files. Every mission uses a dedicated worktree.
- `shared/third_party/codex` is out of scope unless the user explicitly authorizes a separate submodule change.

## Success contract

The goal is complete only when all of the following are true:

1. Send, local echo, RPC, first delta, store application, projection, render, and frame-commit latency are observable end to end.
2. The active stream does not invalidate or copy the whole application state on every delivered token.
3. Sustained streaming stays within the provisional latency and frame-health budgets below on physical iOS and Android devices.
4. Rapid double-send deterministically yields one active turn and one queued follow-up.
5. A slow RPC cannot stop inbound streaming or the global event listener.
6. Reconnect and hydration are bounded, prioritized, and covered by replay and installed-runtime tests.
7. Two-turn, reasoning, tool lifecycle, queued-turn, reconnect, and long-thread acceptance passes on both platforms.
8. Every completed wave is merged through the normal protected-main workflow, then local `main` and `origin/main` are verified at the same commit.

## Provisional budgets

Wave 0 replaces these provisional targets with measured baselines. Later waves may tighten them but may not silently relax them.

| Surface | p50 | p95 | p99 |
|---|---:|---:|---:|
| Keystroke to glyph while streaming | 8 ms | 16 ms | 33 ms |
| Send tap to local echo visible | 40 ms | 80 ms | 150 ms |
| Send tap to `turn/start` on wire, client share | 25 ms | 60 ms | 120 ms |
| First received delta to first visible glyph | 30 ms | 60 ms | 100 ms |
| Rust reduce and emit, 1,500-item thread | 0.2 ms | 2 ms | 5 ms |
| Platform apply and derive per batch | 2 ms | 4 ms | 8 ms |
| Warm thread open, 100 items | 400 ms | 800 ms | 1.5 s |
| Reconnect to live deltas, client share | 300 ms | 800 ms | 1.5 s |
| Turn completion to queued turn sent | 60 ms | 150 ms | 300 ms |

Additional ceilings:

- iOS: less than 5 ms hitch time per second of sustained streaming; zero frozen frames.
- Android: less than 5% janky frames during sustained streaming; zero frozen frames.
- CPU: no more than 25% of one core for a steady stream on the performance-floor device.
- Memory: RSS no more than 300 MB for 1,500 items and no more than 50 MB growth during a ten-minute stream.

## Supervised Pi mission contract

### Runtime

- Agent: Pi coding agent.
- Provider: `homelab`; model ID: `glm-5.2`. The similarly named cloud model is not an allowed fallback.
- Model proof: every mission's Pi event stream must contain `provider=homelab` and `model=glm-5.2` before its work is reviewed.
- Reasoning: `high` by default; `max` is allowed for implementation or integration missions that need it.
- Pi runs with its normal coding tools and explicit project trust inside the mission worktree. It may edit, test, and commit only within the brief.
- One durable Pi session per brief. Resume the same UUID for questions, failures, and review corrections; never create a replacement merely to get a different answer.
- Pi receives no secrets, pairing material, account tokens, private trace contents, or protected submission authority.

### Isolation

Each mission receives:

- A dedicated worktree based on the frozen wave base.
- A branch named `codex/pi-chat-w<NN>-m<NN>-<slug>`.
- Exclusive ownership of the files listed in its task brief.
- A named Pi session `pi-chat-w<NN>-m<NN>-<slug>`.
- The relevant task file as its first prompt.
- A local, ignored `.pi-missions/task-<NN>/` directory containing its event logs, UUID, and review messages.

Missions are not alone in the repository. They must fetch before beginning, must not revert other missions, and must adapt to commits already integrated by the wave coordinator.

### Launch and supervision runbook

Codex is the coordinator and reviewer. Codex creates the branch and worktree from the frozen wave base, verifies a clean status, and launches the task through the repository helper:

```sh
./tools/scripts/pi-mission.sh start <task-number> <worktree>
```

The helper pins `homelab/glm-5.2`, names the mission, preserves the Pi UUID, and records JSON events locally. It does not create the branch, push, merge, publish, or touch another worktree.

The helper also points every mission at one Cargo target cache under the repository's Git common directory and disables Cargo incremental state for that shared directory. Stable compiled artifacts remain reusable across worktrees without cross-worktree incremental dep-graph corruption. Rust missions apply the repository's pinned Codex patch set once before their first Cargo command, keep it applied for the entire validation pass, and restore the submodule only after the final Rust command; patched and unpatched dependency graphs must never alternate in the shared cache. Implementation missions use focused test filters while iterating. Expensive full crate, platform, and workspace suites run once on the combined wave validator, except where a brief explicitly names one final pre-integration gate. A timed-out full suite is recorded and returned to Codex; Pi must not blindly restart it. Codex does not duplicate an unchanged full suite merely to re-prove Pi's valid event-log evidence.

When Pi returns `READY_FOR_REVIEW`, Codex independently reviews:

1. Base and branch identity, changed paths, diff, submodules, and commit scope.
2. Every claim in the handoff against source, commands, fixtures, and produced artifacts.
3. Focused tests plus the task's integration and acceptance surfaces.
4. Security/privacy boundaries, platform parity, Rust-first placement, and performance evidence quality.

Codex records one of two verdicts. `ACCEPTED` means every acceptance criterion is proven. `CHANGES_REQUESTED` lists concrete failures with file/line or command evidence and the exact required result.

For corrections, Codex writes the review to a local file and resumes the same Pi session:

```sh
./tools/scripts/pi-mission.sh repair <task-number> <worktree> <review-file>
```

Pi fixes the rejected work, reruns validation, and returns a new handoff. Codex repeats review until accepted or genuinely blocked. A mission is not allowed to self-approve, and Codex does not quietly repair Pi's implementation instead of sending defects back to the same mission.

Inspect the saved identity and latest turn without launching another agent:

```sh
./tools/scripts/pi-mission.sh status <task-number> <worktree>
```

### Handoff format

Every mission ends with:

```text
MISSION_STATUS
MODEL_PROOF
BASE_AND_HEAD
CHANGES
EVIDENCE
VALIDATION
ACCEPTANCE
RISKS
QUESTIONS_FOR_CODEX
NEXT_MESSAGE_FOR_CODEX
```

`MISSION_STATUS=READY_FOR_REVIEW` means the owned change is committed, scoped tests pass, and evidence is attached. It does not mean Codex accepted the result. A running process, plausible diff, or unit-test-only result is not completion.

### Integration discipline

1. Pi missions make small, scoped local commits as logical pieces validate.
2. Pi never pushes, opens a PR, merges, publishes, releases, or changes authentication.
3. Codex pushes a mission branch only after an `ACCEPTED` review and records the accepted commit in the registry.
4. The wave coordinator fetches each accepted branch and verifies the commit list and changed paths.
5. The wave validator tests the combined wave branch, not isolated mission branches.
6. A wave advances only after its gate passes.
7. After protected-main merge, the coordinator fetches and proves local `main == origin/main` before the next wave freezes its base.

## Wave 0 — Reconcile, instrument, and baseline

**Purpose:** establish current truth, integrate rather than duplicate existing candidate repairs, and make latency measurable before behavior changes continue.

**Frozen base:** `origin/main` plus only the candidate commits accepted by Mission 00.

| Mission | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `pi-chat-w00-m00-reconcile` | investigate, then implement only if evidence requires it | Candidate commits and integration branch | none | Commit-by-commit disposition matrix, integrated candidate base, focused candidate tests plus one final combined Rust gate |
| `pi-chat-w00-m01-rust-observability` | implementation | Shared Rust spans, replay fixtures, perf smoke tests | M00 | Deterministic replay plus store/transport/send spans and CI-safe smoke budgets |
| `pi-chat-w00-m02-ios-observability` | implementation | iOS signposts and fixture metrics | M00 | Send-to-frame signposts and repeatable Instruments lane |
| `pi-chat-w00-m03-android-observability` | implementation | Android tracing, JankStats, Compose metrics | M00 | Send-to-frame traces and repeatable Perfetto lane |
| `pi-chat-w00-m04-baseline-gate` | validation | Combined wave, baseline summaries only | M01-M03 | Cross-platform baseline report and Wave 0 acceptance verdict |

### Wave 0 gate

- Candidate commits have explicit `accept`, `rewrite`, `supersede`, or `reject` dispositions with evidence.
- Replay is deterministic and produces the same final store snapshot across repeated runs.
- Spans cover send tap, local overlay, wire send, first delta, store apply, projection, render, and frame commit.
- Baselines exist for 10/100/500/1,500 items, 100 KB response, code/math/image cases, tool storm, rapid double-send, reconnect, and resume.
- Rust smoke benchmarks are required in CI with generous initial budgets.
- iOS measurements use Release Swift plus `mobile-release` Rust, never the opt-level-0 fast lane.
- No optimization wave begins until the baseline report is committed.

## Wave 1 — Remove per-token state amplification

**Purpose:** eliminate the highest-confidence structural cost before adding more batching.

| Mission | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `pi-chat-w01-m05-shared-stream-state` | implementation | Shared store/update boundary and emit costs | Wave 0 | Narrow active-thread streaming update contract, bounded text accumulation, lower emit cost |
| `pi-chat-w01-m06-ios-state-isolation` | implementation | `AppModel`, screen projection, watch/log side effects | M05 contract | Narrow observable projections; no whole-app invalidation per token |
| `pi-chat-w01-m07-android-state-isolation` | implementation | Android `AppModel`, StateFlows, composer/header collectors | M05 contract | Narrow flows, off-main blocking calls, no O(n²) string concatenation |
| `pi-chat-w01-m08-state-wave-validator` | validation | Combined Wave 1 | M05-M07 | Replay, recomposition/body-update, memory, CPU, and latency verdict |

### Wave 1 gate

- First token remains immediate; no regression beyond the Wave 0 confidence interval.
- Platform apply and derive p95 is at or below 4 ms under 60 deltas/s.
- Rust reduce and emit p95 is at or below 2 ms on a 1,500-item thread.
- Composer keystroke-to-glyph p95 remains at or below 16 ms while another turn streams.
- Non-conversation screens do not re-render or recompose for each token.
- Watch/widget, PiP, home summaries, approvals, and completion state are fresh at their documented cadence and flush on turn settle.

## Wave 2 — Stabilize scrolling and measured rendering costs

**Purpose:** remove render-to-scroll feedback and optimize Markdown or media only where Wave 0/1 profiles prove material cost.

| Mission | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `pi-chat-w02-m09-ios-tail-follow` | implementation | iOS conversation scrolling and row geometry | Wave 1 | One settled, non-animated streaming tail-follow path |
| `pi-chat-w02-m10-android-tail-follow` | implementation | Android LazyColumn, keys, content types, follow loop | Wave 1 | Stable keys and one conflated tail-follow loop with drag protection |
| `pi-chat-w02-m11-profiled-rendering` | evidence-gated implementation | iOS/Android renderer caches listed in brief | M09-M10 plus profile trigger | Only measured renderer/cache improvements; otherwise a documented no-op verdict |

### Wave 2 gate

- A 1,000-token stream does not bounce, yank during drag, or continuously animate the list.
- Loading earlier turns preserves viewport position.
- Long code blocks, math, images, reasoning, and tool rows stay visually correct.
- Android streaming jank is below 5%; iOS hitch time is below 5 ms/s.
- Markdown work is admitted only if parsing/rendering remains at least 10% of main-thread cost after Wave 1.
- Existing iOS `AnyView` row dispatch is not removed without a new trace disproving its documented benefit.

## Wave 3 — Make queues, transport, reconnect, and hydration bounded

**Purpose:** ensure responsiveness survives concurrency, slow RPCs, reconnects, and large histories.

| Mission | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `pi-chat-w03-m12-queue-and-transport` | implementation | Shared turn reservation, queue flush, remote request/event loop | Wave 2 | Atomic rapid-send semantics, non-blocking event ingestion, RPC timeouts |
| `pi-chat-w03-m13-reconnect-and-hydration` | implementation | Shared reconnect/hydration plus thin lifecycle callers | M12 | Prioritized bounded recovery, reduced cloning, evidence-gated legacy shim |

### Wave 3 gate

- Two concurrent sends produce exactly one `turn/start` and one queued draft.
- A queued draft starts within 150 ms p95 of `TurnCompleted` and does not depend on another completion after a transient failure.
- A deliberately slow RPC does not interrupt inbound deltas.
- All unbounded turn/start, steer, resume, and turns-list calls have tested timeouts and retry ownership.
- Reconnect uses bounded concurrency and backoff with jitter; Android no longer invokes duplicate reconnect passes.
- Hydration benchmarks and peak-memory ceilings pass.
- Legacy lifecycle normalization is added only at the JSONL boundary and only if captured frames demonstrate the need.

## Wave 4 — Installed-runtime acceptance and delivery

**Purpose:** prove the complete experience on the actual acceptance surfaces and finish on synchronized main.

| Mission | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `pi-chat-w04-m14-device-acceptance` | validation | Installed iOS/Android apps, evidence artifacts, QA matrix | Wave 3 | Physical-device two-turn/tool/reconnect/long-thread acceptance report |
| `pi-chat-w04-m15-final-integration` | validation; CI/docs or assigned fixes only | CI, QA docs, combined branch | M14 | Full validation, protected-main merge readiness, rollback map, synchronized-main proof |

### Wave 4 gate

- Rust, iOS, Android unit/integration/UI tests pass from a clean checkout.
- Physical iOS and Android devices pass two-turn, queue, reasoning, tool, approval, reconnect, resume, image, code, and long-thread scenarios.
- Provisional budgets have been replaced by recorded p50/p95/p99 results and met on performance-floor devices.
- CI runs replay correctness and non-flaky relative regression checks; device wall-clock measurements remain nightly/reporting unless stability is proven.
- Every workpack task has an evidence-backed disposition.
- The final merge uses the normal protected-main workflow, then local `main` and `origin/main` resolve to the same commit.

## Delegated mission registry

Update this table as missions launch and after every Codex review. Never create a second Pi session for the same row; resume its UUID.

| Task | Pi mission name | Mission status | Review | Branch | Pi UUID | Accepted commit | Brief |
|---|---|---|---|---|---|---|---|
| 00 | `pi-chat-w00-m00-reconcile` | RUNNING | CHANGES_REQUESTED | `codex/pi-chat-w00-m00-reconcile` | `019ff2c5-ca5b-7659-9c70-c62941da9a94` | — | `work/chat-performance/tasks/task-00.md` |
| 01 | `pi-chat-w00-m01-rust-observability` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w00-m01-rust-observability` | — | — | `work/chat-performance/tasks/task-01.md` |
| 02 | `pi-chat-w00-m02-ios-observability` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w00-m02-ios-observability` | — | — | `work/chat-performance/tasks/task-02.md` |
| 03 | `pi-chat-w00-m03-android-observability` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w00-m03-android-observability` | — | — | `work/chat-performance/tasks/task-03.md` |
| 04 | `pi-chat-w00-m04-baseline-gate` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w00-m04-baseline-gate` | — | — | `work/chat-performance/tasks/task-04.md` |
| 05 | `pi-chat-w01-m05-shared-stream-state` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w01-m05-shared-stream-state` | — | — | `work/chat-performance/tasks/task-05.md` |
| 06 | `pi-chat-w01-m06-ios-state-isolation` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w01-m06-ios-state-isolation` | — | — | `work/chat-performance/tasks/task-06.md` |
| 07 | `pi-chat-w01-m07-android-state-isolation` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w01-m07-android-state-isolation` | — | — | `work/chat-performance/tasks/task-07.md` |
| 08 | `pi-chat-w01-m08-state-wave-validator` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w01-m08-state-wave-validator` | — | — | `work/chat-performance/tasks/task-08.md` |
| 09 | `pi-chat-w02-m09-ios-tail-follow` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w02-m09-ios-tail-follow` | — | — | `work/chat-performance/tasks/task-09.md` |
| 10 | `pi-chat-w02-m10-android-tail-follow` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w02-m10-android-tail-follow` | — | — | `work/chat-performance/tasks/task-10.md` |
| 11 | `pi-chat-w02-m11-profiled-rendering` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w02-m11-profiled-rendering` | — | — | `work/chat-performance/tasks/task-11.md` |
| 12 | `pi-chat-w03-m12-queue-and-transport` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w03-m12-queue-and-transport` | — | — | `work/chat-performance/tasks/task-12.md` |
| 13 | `pi-chat-w03-m13-reconnect-and-hydration` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w03-m13-reconnect-and-hydration` | — | — | `work/chat-performance/tasks/task-13.md` |
| 14 | `pi-chat-w04-m14-device-acceptance` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w04-m14-device-acceptance` | — | — | `work/chat-performance/tasks/task-14.md` |
| 15 | `pi-chat-w04-m15-final-integration` | NOT_STARTED | NOT_REVIEWED | `codex/pi-chat-w04-m15-final-integration` | — | — | `work/chat-performance/tasks/task-15.md` |

## Stop conditions

Pause the affected wave and escalate to the coordinator when:

- A mission needs to edit a file owned by another live mission.
- The measured bottleneck contradicts the wave hypothesis.
- A candidate commit cannot be cleanly reconciled with `origin/main`.
- A required acceptance surface is unavailable.
- A change would alter the upstream Codex submodule, wire protocol, stored schema, authentication, release submission, or account ownership.
- The same mission fails three times for the same external reason; mark it blocked rather than spawning replacements.

## Non-goals

- No speculative per-session-store rewrite in the first cycle.
- No cross-platform timeline rewrite in Rust before Wave 0/1 evidence justifies it.
- No Markdown engine replacement by preference.
- No change to vLLM/SGLang execution settings; never disable CUDA graphs or force eager.
- No store publication, release submission, authentication, signing, or payment without the user at the protected boundary.
- No unrelated cleanup or submodule push.
