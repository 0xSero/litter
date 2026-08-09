# Goal: Make Litter chat feel immediate

## Mission

Make Litter chat measurably low-latency, responsive, and robust on iOS and Android without duplicating shared behavior across Swift and Kotlin. The work is executed in waves. Every wave is composed of named Claude Code sessions with explicit ownership, dependencies, deliverables, and acceptance gates.

This file is the orchestration source of truth. Detailed session briefs live in [`work/chat-performance/tasks/`](work/chat-performance/tasks/).

## Ground truth

- Authoritative base at goal creation: `origin/main` at `5f651a475a16c93c273501fd370627f826c5e06f`.
- Candidate branch `codex/local-studio-fidelity-performance` contains four commits not on `origin/main`:
  - `025f7f8b` — Local Studio tool lifecycle compatibility.
  - `f1946f45` — rapid-follow-up serialization and queue tests.
  - `96e77deb` — display-cadence streaming batching.
  - `a4cbf2df` — 2.0 release metadata.
- Wave 0 must disposition these commits before new implementation. Do not reimplement or silently discard them.
- The original checkout may contain dirty submodules and unrelated files. Every session uses a dedicated worktree.
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

## Claude Code session contract

### Runtime

- Model: `fable`, proven through `modelUsage` as `claude-fable-5` before Wave 0.
- Reasoning: `max` for implementation and integration sessions; `high` is acceptable for bounded validation-only resumptions.
- Chrome integration: disabled unless a session explicitly needs a browser acceptance surface.
- Investigation and validation sessions: `--permission-mode plan`.
- Authorized implementation sessions: `--permission-mode acceptEdits`.
- Never use `--dangerously-skip-permissions` or `--bare`.
- One durable session per brief. Resume the same UUID after failure; do not create duplicates.

### Isolation

Each session receives:

- A dedicated worktree based on the frozen wave base.
- A branch named `codex/chat-w<NN>-s<NN>-<slug>`.
- Exclusive ownership of the files listed in its task brief.
- A named Claude session `chat-w<NN>-s<NN>-<slug>`.
- The relevant task file as its first prompt.

Sessions are not alone in the repository. They must fetch before beginning, must not revert other sessions, and must adapt to commits already integrated by the wave coordinator.

### Launch and supervision runbook

The coordinator, not an implementation session, creates each worktree from the frozen wave base. Before the first session in a wave:

```sh
/Users/sero/.codex/skills/manage-fable-sessions/scripts/fable-session.sh doctor <worktree>
/Users/sero/.codex/skills/manage-fable-sessions/scripts/fable-session.sh verify-model <worktree>
```

For a plan/validation brief, store a prompt containing the task file, this GOAL, `scope.md`, and `rules.md`, then launch:

```sh
/Users/sero/.codex/skills/manage-fable-sessions/scripts/fable-session.sh start <worktree> <session-name> <prompt-file>
```

For an authorized implementation brief, launch the named background session from its worktree with the same prompt and the narrow edit mode:

```sh
claude --model fable --effort max --permission-mode acceptEdits --no-chrome --name <session-name> --bg "Read GOAL.md, work/chat-performance/scope.md, work/chat-performance/rules.md, and your assigned task file. Execute only that brief and finish with the required handoff."
```

Supervise without starting duplicates:

```sh
/Users/sero/.codex/skills/manage-fable-sessions/scripts/fable-session.sh list
/Users/sero/.codex/skills/manage-fable-sessions/scripts/fable-session.sh snapshot <short-id>
/Users/sero/.codex/skills/manage-fable-sessions/scripts/fable-session.sh attach <short-id>
```

If a process stops, resume its full UUID from the same worktree with `claude --resume <uuid>`. Record the proven model, permission mode, short ID, full UUID, branch, and base commit in the registry before accepting any work.

### Handoff format

Every session ends with:

```text
STATUS
BASE_AND_HEAD
CHANGES
EVIDENCE
VALIDATION
ACCEPTANCE
RISKS
QUESTIONS_FOR_COORDINATOR
NEXT_MESSAGE_FOR_COORDINATOR
```

`STATUS=complete` means the owned change is committed, its scoped tests pass, and the acceptance evidence is attached. A running process, a plausible diff, or a unit-test-only result is not completion.

### Integration discipline

1. Sessions make small, scoped commits as logical pieces validate.
2. A session pushes only its own branch.
3. The wave coordinator fetches each branch and verifies the commit list and changed paths.
4. The wave validator tests the combined wave branch, not isolated session branches.
5. A wave advances only after its gate passes.
6. After protected-main merge, the coordinator fetches and proves local `main == origin/main` before the next wave freezes its base.

## Wave 0 — Reconcile, instrument, and baseline

**Purpose:** establish current truth, integrate rather than duplicate existing candidate repairs, and make latency measurable before behavior changes continue.

**Frozen base:** `origin/main` plus only the candidate commits accepted by Session 00.

| Session | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `chat-w00-s00-reconcile` | plan, then narrowly authorized edits | Candidate commits and integration branch | none | Commit-by-commit disposition matrix, integrated candidate base, full Rust validation |
| `chat-w00-s01-rust-observability` | acceptEdits | Shared Rust spans, replay fixtures, perf smoke tests | S00 | Deterministic replay plus store/transport/send spans and CI-safe smoke budgets |
| `chat-w00-s02-ios-observability` | acceptEdits | iOS signposts and fixture metrics | S00 | Send-to-frame signposts and repeatable Instruments lane |
| `chat-w00-s03-android-observability` | acceptEdits | Android tracing, JankStats, Compose metrics | S00 | Send-to-frame traces and repeatable Perfetto lane |
| `chat-w00-s04-baseline-gate` | plan | Combined wave, baseline summaries only | S01-S03 | Cross-platform baseline report and Wave 0 acceptance verdict |

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

| Session | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `chat-w01-s05-shared-stream-state` | acceptEdits | Shared store/update boundary and emit costs | Wave 0 | Narrow active-thread streaming update contract, bounded text accumulation, lower emit cost |
| `chat-w01-s06-ios-state-isolation` | acceptEdits | `AppModel`, screen projection, watch/log side effects | S05 contract | Narrow observable projections; no whole-app invalidation per token |
| `chat-w01-s07-android-state-isolation` | acceptEdits | Android `AppModel`, StateFlows, composer/header collectors | S05 contract | Narrow flows, off-main blocking calls, no O(n²) string concatenation |
| `chat-w01-s08-state-wave-validator` | plan | Combined Wave 1 | S05-S07 | Replay, recomposition/body-update, memory, CPU, and latency verdict |

### Wave 1 gate

- First token remains immediate; no regression beyond the Wave 0 confidence interval.
- Platform apply and derive p95 is at or below 4 ms under 60 deltas/s.
- Rust reduce and emit p95 is at or below 2 ms on a 1,500-item thread.
- Composer keystroke-to-glyph p95 remains at or below 16 ms while another turn streams.
- Non-conversation screens do not re-render or recompose for each token.
- Watch/widget, PiP, home summaries, approvals, and completion state are fresh at their documented cadence and flush on turn settle.

## Wave 2 — Stabilize scrolling and measured rendering costs

**Purpose:** remove render-to-scroll feedback and optimize Markdown or media only where Wave 0/1 profiles prove material cost.

| Session | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `chat-w02-s09-ios-tail-follow` | acceptEdits | iOS conversation scrolling and row geometry | Wave 1 | One settled, non-animated streaming tail-follow path |
| `chat-w02-s10-android-tail-follow` | acceptEdits | Android LazyColumn, keys, content types, follow loop | Wave 1 | Stable keys and one conflated tail-follow loop with drag protection |
| `chat-w02-s11-profiled-rendering` | acceptEdits only if triggered | iOS/Android renderer caches listed in brief | S09-S10 plus profile trigger | Only measured renderer/cache improvements; otherwise a documented no-op verdict |

### Wave 2 gate

- A 1,000-token stream does not bounce, yank during drag, or continuously animate the list.
- Loading earlier turns preserves viewport position.
- Long code blocks, math, images, reasoning, and tool rows stay visually correct.
- Android streaming jank is below 5%; iOS hitch time is below 5 ms/s.
- Markdown work is admitted only if parsing/rendering remains at least 10% of main-thread cost after Wave 1.
- Existing iOS `AnyView` row dispatch is not removed without a new trace disproving its documented benefit.

## Wave 3 — Make queues, transport, reconnect, and hydration bounded

**Purpose:** ensure responsiveness survives concurrency, slow RPCs, reconnects, and large histories.

| Session | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `chat-w03-s12-queue-and-transport` | acceptEdits | Shared turn reservation, queue flush, remote request/event loop | Wave 2 | Atomic rapid-send semantics, non-blocking event ingestion, RPC timeouts |
| `chat-w03-s13-reconnect-and-hydration` | acceptEdits | Shared reconnect/hydration plus thin lifecycle callers | S12 | Prioritized bounded recovery, reduced cloning, evidence-gated legacy shim |

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

| Session | Mode | Ownership | Depends on | Deliverable |
|---|---|---|---|---|
| `chat-w04-s14-device-acceptance` | plan | Installed iOS/Android apps, evidence artifacts, QA matrix | Wave 3 | Physical-device two-turn/tool/reconnect/long-thread acceptance report |
| `chat-w04-s15-final-integration` | plan, edits limited to CI/docs/fixes found | CI, QA docs, combined branch | S14 | Full validation, protected-main merge readiness, rollback map, synchronized-main proof |

### Wave 4 gate

- Rust, iOS, Android unit/integration/UI tests pass from a clean checkout.
- Physical iOS and Android devices pass two-turn, queue, reasoning, tool, approval, reconnect, resume, image, code, and long-thread scenarios.
- Provisional budgets have been replaced by recorded p50/p95/p99 results and met on performance-floor devices.
- CI runs replay correctness and non-flaky relative regression checks; device wall-clock measurements remain nightly/reporting unless stability is proven.
- Every workpack task has an evidence-backed disposition.
- The final merge uses the normal protected-main workflow, then local `main` and `origin/main` resolve to the same commit.

## Session registry

Update this table as sessions launch. Never create a second session for the same row; resume its UUID.

| Task | Session name | Status | Branch | Short ID | Full UUID | Handoff |
|---|---|---|---|---|---|---|
| 00 | `chat-w00-s00-reconcile` | NOT_STARTED | `codex/chat-w00-s00-reconcile` | — | — | `work/chat-performance/tasks/task-00.md` |
| 01 | `chat-w00-s01-rust-observability` | NOT_STARTED | `codex/chat-w00-s01-rust-observability` | — | — | `work/chat-performance/tasks/task-01.md` |
| 02 | `chat-w00-s02-ios-observability` | NOT_STARTED | `codex/chat-w00-s02-ios-observability` | — | — | `work/chat-performance/tasks/task-02.md` |
| 03 | `chat-w00-s03-android-observability` | NOT_STARTED | `codex/chat-w00-s03-android-observability` | — | — | `work/chat-performance/tasks/task-03.md` |
| 04 | `chat-w00-s04-baseline-gate` | NOT_STARTED | `codex/chat-w00-s04-baseline-gate` | — | — | `work/chat-performance/tasks/task-04.md` |
| 05 | `chat-w01-s05-shared-stream-state` | NOT_STARTED | `codex/chat-w01-s05-shared-stream-state` | — | — | `work/chat-performance/tasks/task-05.md` |
| 06 | `chat-w01-s06-ios-state-isolation` | NOT_STARTED | `codex/chat-w01-s06-ios-state-isolation` | — | — | `work/chat-performance/tasks/task-06.md` |
| 07 | `chat-w01-s07-android-state-isolation` | NOT_STARTED | `codex/chat-w01-s07-android-state-isolation` | — | — | `work/chat-performance/tasks/task-07.md` |
| 08 | `chat-w01-s08-state-wave-validator` | NOT_STARTED | `codex/chat-w01-s08-state-wave-validator` | — | — | `work/chat-performance/tasks/task-08.md` |
| 09 | `chat-w02-s09-ios-tail-follow` | NOT_STARTED | `codex/chat-w02-s09-ios-tail-follow` | — | — | `work/chat-performance/tasks/task-09.md` |
| 10 | `chat-w02-s10-android-tail-follow` | NOT_STARTED | `codex/chat-w02-s10-android-tail-follow` | — | — | `work/chat-performance/tasks/task-10.md` |
| 11 | `chat-w02-s11-profiled-rendering` | NOT_STARTED | `codex/chat-w02-s11-profiled-rendering` | — | — | `work/chat-performance/tasks/task-11.md` |
| 12 | `chat-w03-s12-queue-and-transport` | NOT_STARTED | `codex/chat-w03-s12-queue-and-transport` | — | — | `work/chat-performance/tasks/task-12.md` |
| 13 | `chat-w03-s13-reconnect-and-hydration` | NOT_STARTED | `codex/chat-w03-s13-reconnect-and-hydration` | — | — | `work/chat-performance/tasks/task-13.md` |
| 14 | `chat-w04-s14-device-acceptance` | NOT_STARTED | `codex/chat-w04-s14-device-acceptance` | — | — | `work/chat-performance/tasks/task-14.md` |
| 15 | `chat-w04-s15-final-integration` | NOT_STARTED | `codex/chat-w04-s15-final-integration` | — | — | `work/chat-performance/tasks/task-15.md` |

## Stop conditions

Pause the affected wave and escalate to the coordinator when:

- A session needs to edit a file owned by another live session.
- The measured bottleneck contradicts the wave hypothesis.
- A candidate commit cannot be cleanly reconciled with `origin/main`.
- A required acceptance surface is unavailable.
- A change would alter the upstream Codex submodule, wire protocol, stored schema, authentication, release submission, or account ownership.
- The same session fails three times for the same external reason; mark it blocked rather than spawning replacements.

## Non-goals

- No speculative per-session-store rewrite in the first cycle.
- No cross-platform timeline rewrite in Rust before Wave 0/1 evidence justifies it.
- No Markdown engine replacement by preference.
- No change to vLLM/SGLang execution settings; never disable CUDA graphs or force eager.
- No store publication, release submission, authentication, signing, or payment without the user at the protected boundary.
- No unrelated cleanup or submodule push.
