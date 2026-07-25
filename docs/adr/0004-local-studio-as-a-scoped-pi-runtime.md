# ADR-0004 — Local Studio is a scoped Pi runtime, not a signed controller plane

- **Status:** Accepted
- **Date:** 2026-07-24
- **Supersedes:** ADR-0001 (canonical Local Studio sessions), ADR-0002 (capability-scoped controller plane), ADR-0003 (signed session discovery cursors) — all three on the unmerged `docs/local-studio-integration-scope` branch.

## Context

Two designs for reaching Local Studio from the phone were built.

**Design A — signed controller plane.** Local Studio exposes a loopback HTTP gateway (`POST /api/litter-bridge/v1`, protocol v1) with Ed25519 per-request signatures, canonical-JSON body hashing, replay protection, an idempotency ledger, and five capabilities (`stats.read`, `models.control`, `sessions.read`, `sessions.write`, `agent.turn`). Alleycat verifies the signature, binds it to the QUIC peer identity, checks a per-endpoint grant, and forwards. Mobile speaks five `localStudio/*` JSON-RPC methods.

This exists and is tested on both ends:

- `local-studio`: `services/agent-runtime/src/litter-bridge-gateway.ts` (+ contract and mutation ledger), ~4,600 lines, 26 security tests. **Live on every desktop install.**
- `alleycat`: `crates/local-studio-proto` + `crates/alleycat/src/local_studio.rs`, ~5,000 lines, 40 tests. **Dead code since `f443a83`.**

**Design B — scoped Pi runtime.** Alleycat constructs a second `PiBridge` pointed at Local Studio's own `PI_CODING_AGENT_DIR`, isolates its thread index under `<agent_dir>/bridge-index`, and scopes `model/list` with `model_provider_prefix("local-studio")`. Mobile discovers it as an ordinary agent and reuses the existing thread, model, streaming, and filesystem surfaces unchanged.

Design B is what ships. This ADR records that and retires A.

## Decision

**Local Studio is an agent runtime, addressed exactly like `pi`, with the same trust level as `pi`.**

1. Session ownership stays with Local Studio's Pi session store; the phone attaches to those JSONL sessions rather than importing or mirroring them. This preserves ADR-0001's *intent* (one canonical session) while dropping its mechanism (a signed session-transfer protocol).
2. There is no capability plane and no per-device grant. Authorization is the alleycat host pair token, full stop.
3. Reconnect uses the generic alleycat session registry and `_alleycat_seq` cursor — the same replay path every other agent uses. ADR-0003's bespoke signed cursors are not needed.
4. Controller telemetry (GPU, metrics, recipes, model lifecycle) is **out of scope for the bridge**. Litter reaches GPU controllers over direct HTTP with a bearer key, which is a separate, already-shipped transport.

## Consequences

**Gained.** The whole feature is ~200 lines of runtime discovery plus a `ProcessLauncher` decorator. Every existing mobile affordance — thread list, model picker, streaming, tool timeline, file search, approvals — works with no new UI, no second protocol stack, and no second state machine. Verified end to end by `tools/scripts/local-studio-e2e-proof.sh`.

**Lost.** Design A's `SessionAuthority: ["local-studio", "litter"]`, session-transfer envelopes, transfer cursors, and content hashes described bidirectional handoff with explicit conflict resolution. Design B has no session-authority concept: the phone reads and appends to Local Studio's sessions directly, and concurrent desktop/phone edits are mediated by Pi's own append-only transcript rather than by optimistic `revision` checks. **Simultaneous editing of one session from both devices is not a supported scenario.**

**Accepted risks.**

- *Trust.* Any holder of the pair token gets a full app-server surface over Local Studio's Pi home, and the runtime is forced to `AskForApproval::Never` + `SandboxMode::DangerFullAccess`. Local Studio's pairing UI states this ("grant access to all agents enabled on this controller"). Because the grant model no longer gates anything, the `kittylitter local-studio grant|revoke|list` CLI must be removed or re-wired — tracked at `0xSero/alleycat#31`.
- *Discovery brittleness.* Runtime resolution is a shell probe over hardcoded candidate paths, including a path into Local Studio's Next.js standalone bundle. A packaging change in Local Studio breaks phone access with no version negotiation. Mitigation requested at `sybil-solutions/local-studio#265`: publish `piAgentDir` and `piRuntime` in the already-existing `litter-bridge.json` descriptor so discovery becomes a read.
- *Dead code in two repos.* Design A remains compiled-but-unreachable in alleycat and live-but-unconsumed in local-studio. Both should be deleted or wired; leaving them invites a future reader to assume they are load-bearing.

## Revisiting

Reopen this decision if any of the following becomes a requirement:

- editing one Local Studio session concurrently from desktop and phone;
- per-device revocation that survives token compromise;
- controller telemetry or model lifecycle control from the phone;
- exposing Local Studio to a device that should *not* have full host access.

Each of those is what Design A was for, and Design A's implementation is still recoverable from git history in both repos.
