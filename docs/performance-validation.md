# Performance validation

This is a measurement record for the performance work based on `a2f39d17`, recorded
on 2026-09-24. The measurements span successive commits on `perf/measured-mobile-host`;
individual results below identify their scope and whether later changes supersede them. The results establish specific improvements and regression coverage; they do
not establish production startup latency, a percentile ranking, or absence of all
memory and storage leaks. Final native and device acceptance is still pending.

## Session derivation: isolated host microbenchmark

The baseline and candidate compile the production `SessionsTypes.swift` and
`SessionsDerivation.swift` with Apple Swift 6.2 and `swiftc -O` on Apple Silicon.
Value-only declarations extracted from the generated UniFFI Swift bindings retain
the actual 624-byte `AppSessionSummary` stride. This experiment does not call Rust,
load the application, render UI, or contact a server.

Each fixture contains one parent and either 100 or 1,000 child sessions in one
workspace, with distinct timestamps. Each process performs seven derivations and
verifies a selected child's sibling projection after each timed derivation. The
timer includes the baseline's eager sibling construction; the candidate's selected
sibling projection happens outside the timer. `/usr/bin/time -l` captures whole
process maximum resident memory, including those sibling reads. Concurrent host
work caused substantial variation, so these samples are diagnostic rather than
device latency budgets or percentile estimates.

| Children | Baseline median ms (min–max) | Candidate median ms (min–max) | Baseline maximum RSS | Candidate maximum RSS |
| --- | --- | --- | --- | --- |
| 100 | 11.216 (2.270–62.911) | 3.207 (1.976–32.865) | 25,477,120 B | 11,173,888 B |
| 1,000 | 684.420 (475.308–848.640) | 20.865 (11.795–62.692) | 854,589,440 B | 28,835,840 B |

At 1,000 children, median derivation duration fell by approximately 32.8 times and
peak process RSS fell by 96.6% in this experiment. Retained lineage array entries
fell from 1,000,000 to 1,000: the candidate stores children once and derives siblings
when requested. These are exact logical element counts, not allocator counts. The
corresponding summary payload lower bound is 624 MB versus 0.624 MB; other linear
projections remain allocated.

Local diagnostic evidence is under
`artifacts/performance-steward/session-derivation/`: exact before/after source
copies, extracted types, fixture runner, JSON results, resource reports, and host
regression output. Those generated artifacts are not part of the public source
tree. The committed regression fixture is
`apps/ios/Tests/LitterTests/SessionsDerivationTests.swift`.

## iOS viewport component measurements

The completed `ios-focused-3` run used a Debug arm64 iOS simulator build with the
iOS 26.0 SDK. It passed 26 tests with zero failures in 4.790 seconds of test time:
14 home dashboard support tests, four session derivation tests, three viewport
geometry tests, four viewport scalability tests, and one model lifecycle test.
This run preceded the final pinch anchoring and idle animation fixes; it is not
acceptance of the final candidate.

| Operation | Fixture and sample count | Observed duration |
| --- | --- | --- |
| Initial viewport creation and apply | 1,000 synthetic sessions, 390 × 800 view, zoom level 2, ten XCTest samples | Mean 30.732 ms; 29.337–32.557 ms |
| Visible range lookup batch | 1,000 lookups into 100,000 fixed-height frames per sample, ten XCTest samples | Mean 1.411 ms per batch; 1.323–1.931 ms |

The mount measurement includes view construction, layout, apply, and its bounded
mount assertion. Fixture construction is outside the timed block. The lookup
measurement includes XCTest assertions and excludes frame-array construction.
Neither result measures a display frame, input-to-presentation latency, navigation,
network hydration, or app launch. There is no matched native baseline for these
two measurements.

The completed tests verify that a 1,000-session list mounts fewer than 50 rows at
initial zoom 2, releases an offscreen hosting tree, reaches the final row, and clears
rows for an empty list. All four zoom levels retain bounded mounts. Page-fit zoom
retains the complete 800,000-point content extent with at most three mounted rows
in its fixture. These bounds apply to the tested viewport and fixture, not every
device size or text setting.

Four subsequent geometry regressions passed in an isolated host harness using the
production geometry helper and minimal value types: deep pinch page-fit anchoring,
different pinch finger positions, offscreen height invalidation, and insertion or
reordering above the viewport. Swift preconditions replace XCTest in that harness;
the native versions and final idle-animation regression still need the coordinated
native rerun.

## Manual component harness and current acceptance

Debug builds accept `--ui-test-home-sessions`. The harness embeds the production
`HomeSessionsScrollView` with 1,000 synthetic sessions, four zoom controls, deep
scroll actions, mounted-row counters, swipe callbacks, and a local detail screen
with native Back navigation. It exercises the component; it does not exercise the
real conversation transport, hydration, or production navigation teardown.
`HomeSessionsUITests` covers deep row opening and Back at every zoom, pinch, swipe,
scroll movement, and bounded mounts.

The first UI run exposed continuously paused pinch-blur animators on idle rows,
causing XCTest animation-idle waits. Idle rows now create those animators only when
needed and dispose of them after the gesture. A regression covers newly mounted,
reattached, and accessibility-updated idle rows. The subsequent native functional run passed the plain pinch/swipe/scroll test
and deep-row open/Back tests at all four zoom levels. The interrupted first run
is not a pass or a usable navigation timing measurement.

`MobilePerformanceUITests.testMainHomeLaunchPerformance` adds a separate launch
measurement with no fixture flags or preference overrides. It records XCTest's
first-frame/main-thread-responsive launch metric and wall time through a hittable
Home Settings control. Run it on a dedicated simulator without a restored
conversation. It never clears user data. Repeated launches retain OS caches and
must not be described as cold-install measurements.

The four `testHomeSessionsOpenBackResourcesZoom*` tests each record five measured
samples plus XCTest's discarded warm-up. Each sample performs two open/Back cycles
at session 900 using the synthetic production-viewport harness. App-process CPU
and memory metrics exclude launch, zoom setup and deep scrolling; wall duration
includes event injection, idle waits and assertions. The app stays alive across
samples. These tests have been added but their results are pending, and their
memory metric does not establish a retained-object leak slope.

The Debug `BackToHomeAppear` signpost measures the actual final conversation Back
callback through the recreated Home view's SwiftUI `onAppear` on compact layouts.
It excludes nested navigation, interactive edge-swipe pop, and split layouts. Its
endpoint is appearance callback delivery, not a displayed frame or touch latency.

The native functional run `ios-final-functional` passed 296 unit tests and 14 UI
tests, with one rich-session pinch failure (310/311 total). This includes native
snapshot-fence, controlled asynchronous AppModel, lifecycle, and compact-lineage
regressions. The rich fixture retains a 1,000-member fork family. Its original
pinch scale 0.7 did not cross the page-fit snap threshold; scale 0.5 corrected the
input, but one subsequent run still failed. Diagnostic repeats then passed,
including two consecutive runs with only terminal gesture-state tracing and no
fixed sleep or hierarchy-dump delay. Both traced recognizer endings committed
zoom 2 from zoom 4, retained session 900, and completed open/Back. No production
gesture semantics changed during this investigation; the intermittent failure
remains unexplained. Whole XCTest durations are not interaction latency.

Android `:app:testDebugUnitTest` passed all 80 tests in 18 suites. Both APK builds
passed, and the rebuilt Rust library was installed on the API 37 arm64 emulator.
The first native instrumentation run passed nine tests and exposed one real
text-selection/link-handling ordering failure. The corrected implementation sets
selectability before restoring link movement handling. A stronger regression
checks link touch dispatch and arbitrary buffer selection across true/false/true
reconfiguration; all ten native instrumentation tests passed after supplying layout parameters
for the standalone test view. The link regression dispatches actual MotionEvents
and selects a buffer range on the main thread; it does not verify attached
long-press selection handles or action-mode presentation. The shared Rust
library suite passed 844 tests with zero failures and three ignored tests, including
idle subscription cancellation, removed-thread cache cleanup, removed-server
launch-row cleanup, and launch-cache projection without cloning conversation history.
This host run precedes the subsequent revisioned streaming change and does not
establish acceptance of that change. Installed native builds have their own test
records and must be rebuilt again when the shared library changes.

An isolated Kotlin 2.0.21/OpenJDK 21 stress harness also ran exact extracted
production Android snapshot/cache projection methods with value-only records and
a volatile flow stand-in. The baseline lost concurrent hydration updates (206 of
800 distinct threads survived that schedule). With the in-memory mutation lock,
eight rounds of eight writers retained all 800 threads, and eight further rounds
with 200 concurrent full-resync merge/prune passes preserved all hydrated payloads.
Authoritative pruning and remove/restore invariants passed. These are correctness
checks, not timing measurements or Android integration tests. Local source copies
and output are under `artifacts/performance-steward/android-projection/`.

## Compact fork ancestry: matched Android host experiment

The production lineage projection was extracted into a Kotlin/OpenJDK host
runner. Five before/after samples used 1,000 unrelated sessions and a 1,000-session
linear fork chain. Both processes ran on the same Mac under concurrent build
load; this is not an Android frame or launch benchmark. The runner checks output
counts and measures per-thread allocation and post-GC retained-heap deltas.

| Fixture | Baseline median | Candidate median | Baseline allocated bytes | Candidate allocated bytes |
| --- | --- | --- | --- | --- |
| 1,000 unrelated sessions | 1.290 ms | 1.828 ms | 842,336–860,344 B | 874,256–880,672 B |
| 1,000-session fork chain | 55.292 ms | 2.062 ms | 72,176,840–72,198,224 B | 899,768–901,248 B |

The unrelated fixture shows a small absolute regression in this noisy host run;
the pathological chain improves by about 26.8 times with approximately 98.8%
less allocation. Retained ancestry references fall from 499,500 to 3,990.
Post-GC retained heap for the chain was about 14.2 MB before and usually 196 KB
after, with one candidate sample at 679 KB; this is not a precise heap profiler.
The UI explicitly indicates omitted ancestors: it retains the root/oldest loaded
ancestor and nearest three ancestors, while the full sibling family remains
available through lazy horizontal rendering. Both native platforms use this
projection rule. Tests cover missing parents, server boundaries and malformed
cycles. Evidence is under `artifacts/performance-steward/android-home-membership/`.

## Kittylitter daemon and transport

The separately prepared 0.3.11 wrapper pins Alleycat `c27278bf`. Its release
preparation is [PR #381](https://github.com/0xSero/litter/pull/381); the mobile
performance candidate retains the published 0.3.10 download links until the new
artifacts are available and validated. An isolated real daemon loaded 1,000
header-only native Pi session files in a temporary home and Git project, with only
Pi enabled and no model credentials. A client using the mobile app's locked Iroh
1.0.3 connected to the host's Iroh 1.2.0 over explicit loopback. It sent no prompts,
`thread/start`, or `turn/start` requests.

Each of three cycles fetched forty pages of 25 sessions, checking all 1,000 native
session/thread IDs exactly once, then repeated the first page 100 times. All 420
authenticated listings passed. Persisted index hydration took 281 ms; first-page
times were 234, 79, and 106 ms. Warm first-page medians were 77–80 ms and p95 values
137–170 ms. These listing results include actual adapter work; they are distinct
from an empty `list_agents` transport probe (local p50 0.994 ms, p95 1.418 ms).
The normal discovered relay path for that transport probe measured p50 295 ms and
p95 329 ms, so local timings do not establish remote interaction latency.

Across the three listing cycles, daemon RSS moved from 59,568 KiB to 58,992,
61,632, and 63,840 KiB, then 59,056 KiB after idle. File descriptors stayed at 25
after startup; the process tree peaked at 190,560 KiB with two descendants.
Disk growth was 48,010 bytes of logs and initialization metadata, and the 1,000
fixture files stayed unchanged. Graceful shutdown exited zero with no surviving
children. This bounded test does not prove that arbitrary transcripts, every
adapter, or long-running production use is leak-free. Reproduction source, locks,
reports, and logs are retained in `artifacts/performance-steward/kittylitter-0311/`.

The host pull request contains adapter/settings changes inherited from the
previously shipped `dcda34d` pin as well as these performance fixes. Its complete
delta against upstream main is broader than a standalone performance patch;
[PR #54](https://github.com/0xSero/alleycat/pull/54) documents that review scope.

## Remaining release gates

- Run the final focused iOS suites and UI harness after rebuilding current Rust
  libraries and bindings. Run Android tests and install the current build.
- On physical iOS and Android devices, measure cold and warm launch to usable
  content, first interaction, conversation open, Back, scroll, swipe, and pinch at
  100 and 1,000 sessions. Record hardware, OS, build, thermal state, repetitions,
  input-to-presentation timing, and frame hitches.
- Repeat deep scrolling and open/Back cycles with real streaming conversations,
  variable Markdown and images, text scaling, rotation, and all zoom levels.
  Confirm stable session position during updates and no stuck input or animation.
- Profile memory, retained view/model/subscription instances, CPU at idle and under
  streaming, and on-disk growth through repeated navigation and reconnect cycles.
  A bounded row count and one deallocation test do not prove a leak-free app.
- Exercise connection loss, cancellation, server removal, background/foreground,
  and shutdown with real transport. Verify that failures and cancellations finish
  cleanly and surface appropriate state. Retain bounded network deadlines rather
  than allowing stalled operations to run indefinitely.
- Validate the packaged Kittylitter install and launch on supported targets,
  including session pagination and cache/log retention, independently of mobile
  component results.
- Record final commit IDs and artifact versions, then verify store processing,
  submission, and review state separately. A build, upload, or test pass does not
  imply App Store or Google Play approval or availability to users.

Use the native build and test commands in [DEVELOPMENT.md](DEVELOPMENT.md).
Preserve raw measurements for each final artifact and update this record with
observed results before claiming the remaining gates are complete.

## Android Activity teardown ownership

`MainActivity.onDestroy` previously used `runBlocking` on the main thread to await
`shutdownAlleycatEndpoint`, capped at 2,500 ms. This made Activity destruction wait
for a network close handshake. It also closed the process-shared endpoint during
Activity recreation or while push refreshes and the pet overlay still used it.
Rust stores that endpoint in a `OnceCell`; later access clones the same endpoint,
and shutdown does not clear or replace it. An Activity is therefore not a valid
owner of endpoint shutdown, even when `isFinishing` is true.

The Activity now only calls `AppModel.stop()` to release its subscription reference
before `super.onDestroy()`. No detached close coroutine can race a replacement
Activity. Android process termination reclaims the native endpoint; background
and reconnect policy remain in the existing shared runtime.

`MainActivityLifecycleTest` binds the native endpoint, recreates the real Activity
three times, checks that each replacement uses the same process model, and records
elapsed time to its main-thread callback. This is a responsiveness and ownership
smoke test, not proof of transport usability or a device latency budget. Native
execution is pending the coordinated Android run. Endpoint identity or secret-key
readback alone cannot establish liveness because a closed endpoint retains both.
The separate runtime gate is an authenticated host RPC before and after Activity
recreation and finish/relaunch in the same process, including with the overlay
service active. No paired Android host was available for that check in this pass.
