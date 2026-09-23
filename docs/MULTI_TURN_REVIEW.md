# Multi-turn history and rendering review

Follow-up sends must retain earlier history and its expansion state. History
truncation belongs to explicit edit/rollback actions. Server turn IDs remain
authoritative boundaries, including turns without a user-message event.

## Findings and changes

| Failure | Change |
|---|---|
| iOS forced collapse at 200 items even with the setting off; a follow-up queued transcript updates behind a collapse animation. | Removed the threshold and animation queue. Apply follow-ups immediately and preserve existing expansion choices on both platforms. |
| One lazy row held an entire turn, eagerly creating every message/tool view inside a long turn. | Flatten expanded turns into individually keyed lazy entries. Collapsed summaries remain single entries. |
| Late turn provenance changed render identity, and post-group merges combined different server turns. | Stabilize row identity and respect server boundaries. |
| Idle repair could replace newer events or an optimistic follow-up with a stale read response. | Check item/overlay revisions and idle status atomically before applying the read. Retry incomplete durable history without resurrecting a completed turn. |
| A completed history response could omit the latest locally completed turn while persistence lagged. | Require the latest observed turn to be present and fully loaded before accepting idle repair. |
| A late completion for turn A could stop turn B and clear its queued steer. | Apply completion cleanup only when it does not conflict with the current active turn. |
| Read/resume could omit the active turn or return mixed full/skeleton turns. | Preserve missing live history; replace only explicitly full turns in a partial response and retain pagination state. Rollback retains its separate path. |

Both projections cache row descriptors for unchanged turns. Android also retains
lazy row state through disposal and avoids rebuilding diff summaries on unrelated
text deltas. These are render projections; Rust remains the runtime state owner.

## Comparable implementations

- [assistant-ui's virtualized transcript](https://github.com/assistant-ui/assistant-ui/blob/main/examples/with-virtualized-thread/app/VirtualizedThread.tsx)
  separates stable message identity/membership from changing content. Its
  [scroll guidance](https://www.assistant-ui.com/docs/guides/virtualization)
  also calls for one owner of auto-follow and measurement compensation.
- [Codex TUI](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget.rs)
  separates committed history cells from a mutable active cell. This supports
  keeping completed projections stable rather than reprocessing all history.
- [Vercel AI SDK](https://github.com/vercel/ai/blob/main/packages/ai/src/ui/chat.ts)
  appends normal sends and reserves truncation for explicit replacement/edit
  operations, with stream writes targeting the active assistant message.

## Validation contract

Regression coverage includes follow-ups across the old 200-item threshold,
500-message turns, late provenance, explicit turn boundaries, retained expansion,
pagination, stale idle reads, late completions, and partially loaded history.
UI fixtures exercise the production mobile timeline surfaces. Host Rust tests
exercise shared reconciliation independently of installed mobile native libraries.

Verified locally on 2026-09-23:

- Shared Rust library: 833 tests passed, 3 existing tests ignored.
- iOS: app/test targets built; 26 targeted unit tests and both simulator UI
  tests passed. Actual follow-up taps preserved earlier messages with collapse
  enabled; the 500-message fixture retained history after a follow-up and scroll.
- Android: 71 unit tests passed, including 13 turn/presentation regressions;
  APK assembly and the Compose emulator test passed.
- Android's 500-message fixture mounted 9 of 502 rows, then 9 of 504 after a
  follow-up, and scrolled back to the retained initial messages. The fixture
  uses fixed-height content with the production lazy-list helper; it measures
  virtualization structure, not rich-markdown render latency.

Local logs and screenshots are under `artifacts/conversation-turns/` (ignored
build evidence). Mobile UI tests used existing generated native libraries; the
changed Rust reconciliation was validated by the host suite. Rebuild the native
libraries for both platforms before packaging a release containing these fixes.

A passing fixture or build does not establish production-server latency. A real
device session should still measure frame pacing while streaming a long tool turn,
scrolling into older pages, interrupting/resuming, and sending rapid follow-ups.
No numeric speedup or production deployment is claimed by this review.
