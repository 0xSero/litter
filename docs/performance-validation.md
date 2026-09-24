# Performance validation

This is a measurement record for the performance work based on `a2f39d17`, recorded
on 2026-09-24. The candidate was an uncommitted development worktree at measurement
time. The results establish specific improvements and regression coverage; they do
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
reattached, and accessibility-updated idle rows. A fresh UI run is required; the
interrupted run is not a pass or a usable navigation timing measurement.

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

Android `:app:testDebugUnitTest` and `:app:assembleDebug` completed successfully in
the earlier native run. Shared subscription cancellation and subsequent lifecycle
changes require regenerated bindings and a new native run. The final shared Rust
library suite passed 844 tests with zero failures and three ignored tests, including
idle subscription cancellation, removed-thread cache cleanup, removed-server
launch-row cleanup, and launch-cache projection without cloning conversation history.
This host run does not establish that the native apps contain the rebuilt library.

An isolated Kotlin 2.0.21/OpenJDK 21 stress harness also ran exact extracted
production Android snapshot/cache projection methods with value-only records and
a volatile flow stand-in. The baseline lost concurrent hydration updates (206 of
800 distinct threads survived that schedule). With the in-memory mutation lock,
eight rounds of eight writers retained all 800 threads, and eight further rounds
with 200 concurrent full-resync merge/prune passes preserved all hydrated payloads.
Authoritative pruning and remove/restore invariants passed. These are correctness
checks, not timing measurements or Android integration tests. Local source copies
and output are under `artifacts/performance-steward/android-projection/`.

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
