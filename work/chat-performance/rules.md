# Rules: Litter chat performance

## Non-negotiables

1. Treat `origin/main` as the shared source of truth; freeze an explicit base for every wave.
2. Do not touch the user's dirty checkout. Use one worktree, branch, and durable Pi session per delegated mission.
3. Do not duplicate shared state, queue, transport, hydration, or pacing logic in Swift and Kotlin.
4. Do not edit or push `shared/third_party/codex` without separate user authorization.
5. Do not claim a latency win without before/after evidence from the same fixture and build profile.
6. Never disable CUDA graphs or force eager for vLLM/SGLang.
7. Keep authentication, signatures, store publication, payments, and final release submission user-controlled.

## Branching & Hygiene

- Fetch and prune before work; verify the wave base commit.
- Branch as `codex/pi-chat-w<NN>-m<NN>-<slug>`.
- Change only files owned by the mission brief.
- Preserve other missions' commits and adapt after integration.
- Pi makes scoped local commits. Codex pushes only after independent review accepts the mission.
- Wave coordinators integrate only reviewed commits into `codex/chat-performance-wave-<NN>`.
- After protected-main merge, fetch and prove local `main` and `origin/main` resolve to the same commit.

## Pi Mission Operation

- Use Pi with provider `homelab` and model ID `glm-5.2`; do not fall back to the cloud ZAI model with the same ID.
- Prove the actual provider/model from the Pi JSON event stream before review.
- Keep one named, persistent Pi session per task and record its UUID in `GOAL.md`.
- Run Pi only in the dedicated mission worktree with explicit project trust and normal coding tools.
- Resume the same mission UUID for every review correction; never restart to evade prior context.
- Pi must not push, merge, publish, release, alter authentication, or receive credentials/tokens in prompts.
- Codex reviews diffs, tests, evidence, acceptance surfaces, and boundaries. Defects go back to the same Pi mission until accepted or blocked.
- End with the handoff format defined in `GOAL.md`.

## Engineering Practices

- Rust owns canonical chat behavior. Native code owns platform UI, rendering, lifecycle, and measurement APIs.
- Prefer typed update records and narrow projections over stringly status or snapshot patching.
- Preserve the first-token fast path when batching sustained deltas.
- Keep changes reversible and avoid combined behavior plus refactor commits.
- Put compatibility normalization at the wire boundary and require captured evidence.

## Testing & Coverage

- Every task adds or updates realistic unit and integration tests for its changed behavior.
- Pure new modules and reducers require strict branch coverage.
- Replay fixtures must be deterministic, scrubbed, bounded, and versioned.
- Performance gates must report distributions; no single-run pass/fail thresholds.
- Simulator/emulator evidence is functional only. Physical device evidence is required at the wave gates specified in `GOAL.md`.

## Security and Privacy

- Never record prompts, attachments, credentials, account tokens, private paths, or pairing secrets in fixtures or traces.
- Scrub server IDs, user text, and filesystem paths before committing artifacts.
- Commit summaries and aggregate timing only; keep raw device traces local or in access-controlled CI artifacts.

## Definition of Done

- Owned changes are committed and pushed.
- Scoped formatting, unit, integration, and relevant platform tests pass.
- Required performance/acceptance evidence is attached.
- No unrelated files or submodules changed.
- The mission handoff is complete, Codex has recorded `ACCEPTED`, and the registry is updated.
- A wave is done only after its combined validator passes and protected main is synchronized.
