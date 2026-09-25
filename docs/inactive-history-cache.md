# Inactive transcript memory policy

The shared Rust store keeps session identities, titles, and bounded home summaries while treating hydrated inactive transcripts as a reloadable RAM cache. This policy does not write message bodies to disk.

A sweep starts evicting the least recently viewed eligible histories when their combined weight exceeds **64 MiB**, stopping at **48 MiB**. Selecting a conversation only records recency and schedules a coalesced Rust-runtime sweep; it does not count or free histories on the synchronous native selection path. Hydration completion, turn completion, and late final tool completion on an inactive conversation also enforce the budget. Streaming deltas do not run sweeps.

Weight includes owned string and vector capacities, embedded image bytes, a conservative estimate of the item index, and retained derived activity buffers. Unchanged transcript weights are reused by item revision. Counting traverses records and allocation metadata, not image or text bytes. Evicted item buffers are destroyed outside the canonical snapshot write lock.

This is an **eligible inactive cache budget, not a total process-memory limit**. Active, protected, and disconnected histories are excluded. Native projections, decoded-image/render caches, allocator overhead, and session metadata have separate costs.

## Protected work

Histories remain resident while selected, streaming, attached to voice or a handoff, awaiting approval or user input, holding queued drafts or local overlays, performing a server mutation or history operation, or containing unfinished tools/widgets. Active goals and pending plan work are also protected. History-operation guards span pagination requests and response reconciliation; cancellation releases the guard. Currently disconnected or otherwise unhealthy servers are protected.

Composer drafts owned by the platforms are not cleared. Home summaries retain bounded preview/tool strings and scalar conversation statistics; the full transcript is released.

## Reload and offline behavior

Eviction clears the loaded-history flag and older-page cursor, advances the authoritative content capture, and publishes an empty thread update. Both native snapshot and retained-thread projections accept that capture and discard covered old items. Older full snapshots cannot restore stale pagination flags; unversioned metadata updates leave pagination with the current captured history.

Reopening loads the first page again. Legacy servers reload embedded turns when the loaded-history flag is false, even if a late background event has added a partial item. An older-page request cannot race eviction and then falsely mark only that older page as complete history.

Offline availability is **best effort**. Protecting a currently disconnected server preserves history still in RAM; it cannot restore a transcript already evicted while that server was online. Such a conversation needs the server to become reachable again. There is no transcript disk cache or offline-history guarantee.

## Validation

Focused regressions cover allocation capacity, least-recently-viewed eviction, bounded summaries through metadata refresh, protected work, offline/reconnect behavior, cancellation, paging during trim, legacy partial-item reload, and native stale-pagination rejection. The ignored `diagnostic_selection_latency_during_history_trim` test prints concurrent selection latency during a threshold-crossing sweep; those host timings are diagnostic, not device latency claims. Native interaction and memory measurements remain required after rebuilding the shared library.
