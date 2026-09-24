# Performance profile — 2026-09-24 (release 2.1.5)

Where Litter spends time, ranked by what users feel. Sources:

- **Measured, Rust:** ignored benchmarks in
  `shared/rust-bridge/codex-mobile-client/src/perf_profile.rs` (Apple Silicon,
  release build with LTO off). Reproduce from that crate:
  `CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 cargo test --release --lib perf_profile -- --ignored --nocapture --test-threads=1`
- **Measured, Android:** release APK on the `LitterReleaseAPI37` emulator
  (software GPU, so frame numbers overstate jank; startup numbers are usable).
  Trace: `artifacts/litter-start.perfetto-trace`.
- **Static, iOS and network:** code-path audit. No simulator or device run was
  possible (Xcode 26.0.1 simulator hangs on this Mac; no Xcode account for
  device builds). Durations there are estimates.

Already fixed in 2.1.5: home cat decode off the main thread, Rust bridge init
before the first frame, and recent sessions shown at launch from a cache.

## Measured numbers

| What | Size | Result |
|---|---|---|
| Rust full snapshot (clone + projection) | 1000 threads × 200 items | **132 ms median, 265 MB allocated** |
| Rust full snapshot | 50 threads × 200 items | 3.6 ms median, 41 ms p95 |
| Rust full snapshot | 1 thread, 2000 items, 50 KB each | 17 ms, 202 MB allocated |
| Rust thread-list upsert + finalize | 10 servers, 1000 threads | **123 ms median** |
| Rust `ThreadUpserted` | 2000-item thread | 0.47 ms, 1.8 MB |
| Rust streaming, 1000 deltas | 2000 items, 100 KB message | 0.4 ms total (no quadratic growth) |
| Android cold start (`am start -W`) | 10 runs | **1,756 ms median, 2,199 ms p90** |
| Android `bindApplication` → DEX open | trace | **969 ms** of it |
| Android splash | code | fixed **800 ms minimum** after first composition |
| Android APK | release | 102 MB; Rust `.so` 87 MB, Ghostty 29 MB, WebRTC 12 MB |

## Ranked findings

### Launch and connection (biggest user-visible wins)

1. **The local server boots before any remote server starts reconnecting.**
   `ffi/reconnect.rs:417-444` awaits `connect_local` and only then spawns the
   remote `JoinSet` (`:475-490`). Every remote server's "connected" waits for
   the embedded runtime. Fix: spawn the local connect as one more task in the
   same `JoinSet`. Small change.
2. **Android startup: 969 ms of DEX loading, a fixed 800 ms splash, and all of
   Rust/AppModel init on the main thread.** No Baseline Profile exists
   (`bindApplication` 1,031 ms). `MainActivity.kt:101-120` holds the splash
   ≥ 800 ms; `AppModel.kt:133-164` and `UniffiInit.kt:51-59` load the 87 MB
   `.so` and construct every bridge in `onCreate`. Fix: Baseline Profile +
   Macrobenchmark module, drop the fixed splash minimum (hide on first
   content), move init off the main thread like iOS now does.
3. **Android reconnects every saved server twice on launch and resume.**
   `AppLifecycleController.kt:53-60, 125-128`. Offline servers pay their full
   timeout twice (two 10 s SSH connect timeouts = 20 s). Fix: retry only
   retryable per-server failures.
4. **Thread lists load only when a screen asks, and Android lists servers one
   at a time.** Reconnect warms accounts but not thread lists
   (`mobile_client/mod.rs:4147-4174`). Android `AppModel.kt:485-502` loops
   servers under one mutex; each page can wait 10 s. Fix: a first-page list
   right after each server connects; parallel servers on Android.
5. **Opening a conversation always waits for the network.** The launch cache
   holds titles only; opening needs `thread/resume` + `thread/turns/list`, and
   those RPCs have no deadline (`session/connection.rs:1730-1744` only times
   `thread/list` and `model/list`). Fix: prefetch the latest turn page for the
   top 3–5 recent threads after connect; add deadlines to resume/read/turns.
6. **Duplicate work on resume.** Rust resubscribes tracked threads serially
   (`mobile_client/mod.rs:4191-4238`) and iOS refreshes the same threads again
   (`AppLifecycleController.swift:479-488, 533-548`); account probes run
   serially per server (`ffi/reconnect.rs:244-306`) plus iOS keychain retries
   of 3.5 s (`AppModel.swift:707-730`). Fix: one owner (Rust) per connection
   generation, bounded parallelism, visible thread first.
7. **Local Studio holds the whole server until every runtime connects** with a
   6 s retry ladder (`mobile_client/mod.rs:181-184, 2049-2079`). Fix: mark
   partially connected; retry missing runtimes in the background.

### Smoothness while streaming and scrolling

8. **Full snapshots deep-clone every item.** 132 ms / 265 MB at 1000 threads
   (`store/reducer.rs:278-282`, `store/boundary.rs:472-532`). Platforms call
   `store.snapshot()` for refreshes. Fix: a light snapshot without hydrated
   items, with the active thread's items requested separately; or `Arc` item
   payloads so the clone is cheap.
9. **iOS replaces the whole snapshot value ~8 times a second while streaming.**
   `AppModel.swift:1230-1276` copies nested arrays, does linear lookups, and
   reassigns `snapshot`, which invalidates every whole-snapshot observer.
   Fix: keep hot streaming text outside the snapshot, keyed by
   `(thread, item)`; keep index maps across localized updates.
10. **iOS home rebuilds everything on every snapshot change** — 8–12 passes
    over all sessions, string signatures, and a JSON decode of saved servers
    (`HomeDashboardModel.swift:268-356`, `SavedServerStore.swift:18-20`).
    Fix: observe narrow revisions (servers / summaries); cache saved servers
    in memory.
11. **Apple Watch bridge (when enabled) projects and writes UserDefaults on
    every snapshot change** (`WatchCompanionBridge.swift:139-181, 549-555`);
    the 150 ms throttle comes after the work. Fix: throttle before projecting.
12. **Thread-list sync emits one full update per thread** — 123 ms for 1000
    threads (`store/reducer.rs:666-670`). Fix: batch a page under one write
    lock and emit one update.
13. **Long conversations regroup all items on each transcript change**
    (`ConversationView.swift:745-747, 942-958`, `TranscriptTurn.swift:73-100`,
    `ConversationTimelineView.swift:2626-2657`). Fix: update only the live
    turn; append new turns.
14. **Home keeps one `UIHostingController` per session and measures every
    row;** a pinch promotes all rows to the densest layout
    (`HomeSessionsScrollView.swift:136-143, 614-665, 1565-1575`). Fix:
    `UICollectionView` with reuse, measure visible rows only. The planned
    Litter Quiet list makes this simpler.
15. **Images decode on the main thread:** `ResolvedChatImageView.swift:39-54`
    calls `UIImage(data:)` in `body`; sending photos resizes, JPEG-encodes and
    base64-encodes on the main actor (`ConversationView.swift:355-363`,
    `ConversationAttachmentSupport.swift:83-118`). Fix: Nuke or ImageIO
    downsampling off-main; prepare attachments in a task group.

### Battery and size

16. **Per-card 30 fps shimmers and a 1 Hz clock per active card, plus an
    endless pet sprite loop** (`HomeDashboardView.swift:1693-1794`,
    `SubagentCardView.swift:284-311`, `PetSpriteView.swift:209-265`). Fix: one
    shared clock, pause offscreen, 10–15 fps. Litter Quiet removes most of
    these indicators.
17. **iOS launch still does two Keychain reads in `didFinishLaunching` and
    CloudKVS import/export on the main thread at +0–0.5 s**
    (`LitterApp.swift:30-32, 97-99`, `CloudKVSBridge.swift:64-223`).
18. **Android R8 and resource shrinking are off; the Rust library is 87 MB.**
    Enable R8 and audit Rust features/dependencies reachable from mobile.

## Suggested order

| Step | Items | Effort | Expected effect |
|---|---|---|---|
| 1 | 1, 3, 4 (Android parallel list), 10 (saved-server cache) | small | seconds off cold connect; fewer offline stalls |
| 2 | 2 (Baseline Profile, splash, off-main init) | medium | Android cold start well under 1 s of app time |
| 3 | 5, 6 | medium | conversations open without a spinner; lighter resume |
| 4 | 8, 9, 12 | large (Rust boundary) | smooth streaming with many threads; less memory |
| 5 | 13, 14, 15, 16 | medium, overlaps the Litter Quiet redesign | smooth long threads, scrolling, battery |

Confirm iOS items on device with Instruments (Time Profiler, Allocations,
SwiftUI, Hitches); existing `PerfTracker` signposts cover
`HomeDashboardModel.refreshState` and conversation first render.
