# Litter v2.0.1 Delivery Goal

Last updated: 2026-08-14 19:08 EDT

This file is the execution contract for Litter v2.0.1. It records what the user asked for, what is actually proven, what is still failing, and the order in which the remaining work must happen. A green build alone is not completion. The goal ends only after both stores are successfully deployed and obsolete work is safely removed.

## Outcome

Deliver one coherent Litter v2.0.1 release that:

- contains every worthwhile change currently split across branches and pull requests;
- makes long session lists, conversation loading, Back navigation, composing, streaming, and multi-turn follow-ups feel instant;
- stops unrelated views and long lists from re-rendering on every update;
- preserves all current iOS and Android functionality;
- gives the composer a cleaner Codex-like layout and interaction model;
- reduces tracked first-party code by at least 25% against the frozen `origin/main` baseline;
- is fully tested on simulator/emulator and physical devices, with recordings, profiles, size evidence, and review;
- lands as one mega PR with small logical commits;
- is merged so local `main` and `origin/main` are identical;
- is successfully deployed to Apple App Store/TestFlight and Google Play;
- closes obsolete PRs and deletes dead branches/worktrees only after their useful work is captured and the release is proven.

## User request ledger

The following requests are all in scope and must not disappear during implementation:

1. Inspect `origin`, determine the latest deployed app, and reconcile it with the app that was on the user's phone.
2. Bring the authoritative result into local `main` without destroying divergent local work.
3. Review the large line-reduction PR and keep only simplifications that preserve behavior.
4. Reduce total first-party LOC by 25%, with functionality intact.
5. Converge all valuable alpha work into one mega PR with logically separated commits.
6. Close all other PRs and delete dead remote/local branches only after their useful work is captured.
7. Delete outstanding worktrees only after final validation and only after proving they contain no uncaptured work.
8. Test all production features and workflows on iOS and Android.
9. Measure responsiveness, launch/session/conversation latency, scrolling, rendering, app size, and regressions.
10. Use computer-driven UI testing and preserve recordings as evidence.
11. Fix the global re-render problem that makes large project/session/folder lists slow.
12. Make Back navigation from chat immediate, not multi-second.
13. Make multi-turn conversations and rapid follow-up sends reliable, instant, and free of flicker.
14. Make the composer remain responsive and focused during streaming and look more like Codex.
15. Consult and aggregate Fable-5, GLM-5.3, Kimi-K3, and DeepSeek-V4-Pro; obtain a final Claude Code Opus-5 review.
16. Install the latest fixed candidate on the user's iPhone.
17. Finish by successfully deploying the same accepted release to both mobile stores.

## Non-negotiable rules

- `origin/main` is the shared source of truth.
- Start and finish delivery on `main`; final local `main` and `origin/main` must resolve to the same commit.
- Preserve existing dirty state. Do not reset, stash, overwrite, or delete another worktree's changes.
- Shared session/thread/reducer/reconnect logic belongs in Rust when both platforms need it. Swift and Kotlin stay thin.
- Every implementation change gets a small logical commit after its own validation.
- Do not merge, deploy, close PRs, delete branches, or remove worktrees while acceptance is red.
- Do not claim store deployment from a build, upload, or CI job. Verify the actual store state.
- Do not call performance “instant” without measured, repeated evidence on the real app surface.
- The physical-phone sideload is a development candidate, not an App Store release claim.

## Current Git and PR state

### Authoritative refs

| Ref | SHA | State |
|---|---|---|
| `origin/main` | `7122dd6eba57e0c6eb923acd642db9396ade1334` | Live remote-main baseline |
| local `main` worktree | `7122dd6eba57e0c6eb923acd642db9396ade1334` | Matches `origin/main` |
| Tested mega application baseline | `716acabdeea6f6da9e97d5887601f50a488195be` | Pushed candidate installed on the phone and used for Apple acceptance |

PR #295, **v2.0.1 mega convergence**, is open and draft: <https://github.com/0xSero/litter/pull/295>.

- Merge state: `CLEAN`
- Application diff at tested baseline `716acabd`: 33 files, +2,342 / -335 GitHub lines
- Application commits at that baseline: 7 logical commits; this living goal is a separate documentation change
- Mobile CI: shared-prep, Android, and iOS all green at `716acabd`
- Release workflow: planning and Windows final-package test green; publishing jobs correctly skipped because this is not a release-triggering commit
- Local mega worktree: no tracked source changes before this file; only the two pre-existing dirty submodules (`shared/third_party/codex` and `shared/third_party/ghostty`)

The seven tested application commits are:

1. `98981fa8` — conversation typography
2. `d49db8b4` — Studio default appearance
3. `12a7cbb1` — read-only Play status fallback
4. `44b76b53` — render-isolation instrumentation and performance fixtures
5. `57414ba6` — per-thread rebind isolation kernel on iOS and Android
6. `7c4b07b4` — Android concurrency-test correction
7. `716acabd` — cross-platform W1 production-path measurement fixtures and attribution

### Other open PRs that still require disposition

| PR | Branch | Purpose | Current action |
|---|---|---|---|
| #300 | `ci/ish-vdso-guard` | iSH VDSO failure/launch CI | Audit and capture or explicitly reject |
| #298 | `fix/amp-current-modes` | Current Amp mode support | Audit and capture or explicitly reject |
| #297 | `fix/ssh-host-key-change-confirmation` | Changed SSH host confirmation | Audit and capture or explicitly reject |
| #260 | `codex/remove-alleycat-main-refresh` | Remove stale Alleycat refresh | Audit and capture or explicitly reject |
| #254 | `codex/pi-chat-w00-m00-reconcile` | Chat pacing and queued follow-ups | Reconcile into the mega performance work |
| #239 | `codex/local-studio-fidelity-performance` | Local Studio session fidelity/performance | Reconcile useful work into mega |

No PR above may be closed merely to make the list look clean. Each needs a provenance/result record first.

### Existing worktrees

There are currently 14 registered worktrees, including the primary dirty checkout, the `main` worktree, the mega worktree, chat-performance/reconciliation worktrees, and release/testflight worktrees. Cleanup is intentionally deferred. Before removal, each worktree must be checked for:

- tracked and untracked changes;
- commits not reachable from the final mega/main history;
- evidence or release artifacts not copied to their durable location;
- a branch still backing an open PR.

Use recoverable Git worktree removal only after those checks. Never recursively delete a broad directory.

## Phone and store state

### Physical iPhone — completed for the requested sideload

Device: **Sero’s iPhone**, iPhone 15 Pro Max, CoreDevice ID `E64BFB56-4B4A-5BB7-B186-43F023D50EFA`.

- Previous installed app: Litter `2.0.0` build `200000254`
- Installed on 2026-08-14: Litter `2.0.1` build `200010001`
- Bundle ID: `com.sigkitten.litter`
- Source: exact mega commit `716acabdeea6f6da9e97d5887601f50a488195be`
- Build: fresh Rust device library plus a fresh signed Debug/device relink; both build steps succeeded
- Install: `devicectl` succeeded without uninstalling the app container
- Launch: succeeded
- Phone-side verification: installed-app query reports `2.0.1 / 200010001`
- Uncompressed Debug `.app` size: 188 MiB. This is **not** the final release IPA/download/install-size measurement.

This fulfills the immediate request to put the latest candidate on the phone. It does not make the candidate release-ready; Apple acceptance is still red below.

### Apple distribution

- Last verified App Store production state during this task: Litter `2.0.0`, build `200000260`, `READY_FOR_SALE`.
- A fresh local App Store Connect query is currently blocked because the local `asc` CLI has no authentication configuration.
- No v2.0.1 archive has been uploaded or submitted.
- Required end state: accepted release build, TestFlight/device validation, App Store submission/release, and a fresh store query proving the live version/build.

### Google Play

- The release service account was previously proven unable to perform the required release operation because it lacks the needed Play Console release permission.
- No v2.0.1 Play release has been uploaded or promoted.
- Required user/admin boundary: grant the service account the correct app/release permission or complete the authenticated Play Console handoff.
- Required end state: accepted AAB, target-track rollout completed, and a Play query/console check proving the deployed version code and status.

## LOC target — currently red

Frozen measurement command:

```bash
cloc --vcs=git --exclude-dir=third_party,GeneratedRust,Frameworks --csv --quiet
```

This counts tracked first-party code and excludes the two upstream submodules plus generated/package artifacts.

| Tree | Code lines |
|---|---:|
| `origin/main` baseline `7122dd6` | 196,855 |
| Mega candidate `716acabd` | 198,617 |
| Current delta | **+1,762 (+0.90%)** |
| Required 25%-reduced ceiling | **147,641** |
| Reduction still required from mega | **50,976 lines** |

The 25% requirement is not close to complete. GitHub's PR additions/deletions and `cloc` code lines are different metrics; acceptance uses the frozen `cloc` command above. Deletion is only valid when parity tests and product behavior remain intact.

## Apple app acceptance — currently red

Evidence directory:

`/Users/sero/ai/projects/litter-release-evidence/v2.0.1/apple-app-full-716acabd/`

Artifacts include the full log, a 289 MiB `.xcresult`, a continuous 24-minute/852 MiB simulator recording, SHA256 manifest, and `RESULTS.md`.

### Full UI suite result

- Target: actual `com.sigkitten.litter` app on iPhone 17 Pro simulator
- Exact source: `716acabd`
- Result: **18 tests, 13 passed, 5 failed**
- XCTest verdict: `TEST EXECUTE FAILED`

Failures and current classification:

1. Expanded-mode code-block check: pre-W1 XCTest selector defect. The app renders the two-line code block as one accessibility element; the test incorrectly demands an exact standalone `UITEST_CODE_BLOCK` label.
2. Back to Sessions at 300: real W1 fixture-seam defect plus a still-real navigation failure. The fixture seeds the Swift snapshot but lets `resumeThread` and `listThreads` call disconnected Rust transport. Failure-time hierarchy remains on Conversation after Back.
3. Composer typing during foreign stream: unresolved product-vs-fixture behavior. Captured hierarchy has no focused element and no keyboard window; the composer never became first responder.
4. Open conversation/back at 1,500 items: same fixture transport defect plus a real Back failure. Failure-time hierarchy remains on Conversation instead of Home.
5. Session-search clearing: test expectation defect. The field did clear and restored the full list; XCUITest reports the empty field's placeholder value (`Search sessions`) instead of an empty string.

Cross-cutting observed defect: production-fixture navigation sometimes waits about 60 seconds for the app-animation completion notification before XCTest can synthesize the tap.

### Measured current behavior

| Surface | Current measurement | Verdict |
|---|---:|---|
| Five open/Back cycles at 300 sessions | 75.161 s average batch, about 15 s/cycle | Unacceptable |
| Conversation launch | 1.770 s average | Not instant |
| 19-character composer probe | 0.619 s average | Measurable, but focus failed under foreign streaming |
| 1,500-item scroll deceleration | 1.682 s average, 33.3% RSD | Too noisy for a regression claim |
| Foreign-thread body isolation | Zero unrelated TimelineRow/SessionRow/Header/HomeCard evaluations | Structural isolation passes |

The per-thread rebind kernel is implemented, but there is no valid claim that it has made the user-visible operations fast yet.

### Apple diagnosis/review status

- GLM-5.3 source diagnosis: complete at `/private/tmp/glm53-apple-ui-failures-diagnosis.md`.
- GLM-5.3 runtime evidence extraction from the existing `.xcresult` and video: in progress; no new app run or source edit.
- Fable-5 final failure adjudication: held until the runtime evidence is sealed. Interim direction is `AMEND`, not an automatic W1 rollback, but no final artifact exists yet.
- No corrective source patch has been authorized or implemented after this red run.

## Android acceptance

- W1 Android instrumentation and deterministic tests are present at `716acabd`.
- Mobile CI successfully generated bindings, built JNI/Android, assembled the app, and passed Android unit tests.
- No current full Android emulator/physical-device feature recording has been accepted for the final v2.0.1 candidate.
- No final Android performance baseline, release AAB size report, or Play deployment exists yet.

Android is CI-green but not release-complete.

## Consultant and reviewer ledger

Completed inputs include:

- GLM-5.3 implementation/diagnosis lanes for iOS and Android W1.
- Kimi-K3 instant-performance audit: `/Users/sero/ai/projects/litter-release-evidence/v2.0.1/perf-0b/kimi-k3-instant-performance-audit.md`.
- DeepSeek-V4-Pro instant-session audit: `/Users/sero/ai/projects/litter-release-evidence/v2.0.1/perf-0b/deepseek-instant-session-perf-audit.md`.
- Fable-5 W1 diff review: `/Users/sero/.claude/plans/fresh-fable-5-w1-floating-diffie.md` (`PASS` for that exact W1 diff before the later full-suite failures were discovered).
- Fable-5 residual performance plan and protocol amendments under `/Users/sero/.claude/plans/`.

Still required:

- final Fable-5 adjudication of the real Apple UI failures;
- GLM-5.3 implementation of only the authorized corrective workpack;
- independent regression review after each performance/LOC slice;
- final Claude Code Opus-5 review of the complete release diff and evidence;
- explicit aggregation showing which Kimi/DeepSeek/Fable recommendations were accepted, rejected, or superseded.

## Remaining work, in order

### Gate 0 — preserve the current phone candidate and evidence

- [x] Build `716acabd` for the physical iPhone.
- [x] Install and launch `2.0.1 (200010001)`.
- [x] Verify the version from the phone.
- [ ] Have the user confirm the app opens and retained expected account/server state.

### Gate 1 — finish Apple failure adjudication

- [ ] Seal GLM's existing-runtime evidence report.
- [ ] Have Fable read the report and issue the exact amend/revert ruling.
- [ ] Record a minimal file allowlist, tests, commit subject, and rollback condition.

### Gate 2 — repair the Apple test/fixture failures

- [ ] Fix the two invalid XCTest expectations without weakening behavior checks.
- [ ] Prevent fixture-mode Home/Sessions actions from using disconnected production transport.
- [ ] Determine why Back remains on Conversation.
- [ ] Determine why the composer cannot acquire focus during foreign-thread streaming.
- [ ] Attribute and eliminate the 60-second animation/quiescence stall.
- [ ] Commit each logical correction separately.
- [ ] Run the focused failures, then all iOS unit tests, then the full 18-test UI suite with a new continuous recording.

### Gate 3 — deliver the actual performance fix

- [ ] Profile real session loading, Home/Sessions derivation, navigation path mutation, conversation hydration, composer focus, and streaming update propagation.
- [ ] Move shared reconciliation/derivation work into Rust where both platforms need it.
- [ ] Virtualize or page large lists and avoid whole-corpus hydration where evidence identifies it as the cost.
- [ ] Ensure foreign-thread updates do not invalidate the displayed conversation or composer.
- [ ] Ensure rapid follow-ups queue/send deterministically without flicker, lost input, duplicate sends, or whole-screen invalidation.
- [ ] Re-run at 300 sessions, 1,500 items, and a larger real-world corpus.
- [ ] Require repeated p50/p95 measurements and recordings on both platforms.

### Gate 4 — Codex-like composer acceptance

- [ ] Compare against the provided Codex composer reference.
- [ ] Preserve attachment, project/folder, web, model, voice, and send controls.
- [ ] Keep the text surface stable while models/streaming/session state updates.
- [ ] Verify keyboard focus, dictation, long model names, rapid follow-ups, and accessibility.
- [ ] Capture simulator and physical-device screenshots/video.

### Gate 5 — full feature parity matrix

Test on iOS and Android, using real connected services where required:

- launch, onboarding, theme, settings, and persistence;
- Kittylitter, Local Studio, connected-computer, direct URL, SSH, pairing, and reconnect;
- Home, projects/folders, sessions, search, pagination, resume, new thread, rename/archive/delete;
- message rendering, reasoning/system sections, Markdown/code/diff/tool calls/images;
- streaming, multi-turn, follow-ups, steer, stop, retry, approvals, and user input requests;
- composer attachments, model/reasoning controls, web, voice/dictation, and keyboard behavior;
- notifications, backgrounding, Live Activities/watch surfaces where applicable;
- terminal/shell and saved-app flows;
- offline/error/reconnect and state restoration;
- accessibility, rotation, light/dark themes, memory pressure, and long-list stress.

Every row needs a pass/fail result, platform/build identity, and evidence link. “CI green” is not a substitute for device behavior.

### Gate 6 — size and performance report

- [ ] Produce signed Release IPA and AAB artifacts.
- [ ] Record archive, compressed download, and installed sizes separately.
- [ ] Attribute the largest binaries/resources/dependencies.
- [ ] Compare v2.0.1 with the live 2.0.0 builds.
- [ ] Record cold/warm launch, session load, conversation open, Back, typing, scroll, multi-follow-up, CPU, memory, hangs, and dropped frames.
- [ ] Keep raw traces, commands, manifests, and recordings.

### Gate 7 — 25% LOC reduction without lost functionality

- [ ] Inventory duplicate Swift/Kotlin logic that belongs in shared Rust.
- [ ] Audit generated, copied, obsolete, dead, and superseded modules.
- [ ] Prefer deletion/consolidation over new abstraction layers.
- [ ] Land deletion slices with focused parity tests and size/build evidence.
- [ ] Reach at most 147,641 tracked first-party code lines under the frozen command.
- [ ] Re-run the complete feature/performance matrix after the final deletion.

### Gate 8 — single mega PR and final review

- [ ] Reconcile all open PRs and branches into an explicit keep/drop ledger.
- [ ] Ensure all kept work appears in PR #295 as logical commits.
- [ ] Update PR purpose, changes, tests, measurements, screenshots, and known limitations.
- [ ] Obtain GLM-5.3 review, Fable-5 plan/diff review, and Claude Code Opus-5 final review.
- [ ] Resolve every blocking review item.
- [ ] Require all CI and device gates green at the final SHA.

### Gate 9 — merge and synchronize main

- [ ] Merge the accepted mega PR.
- [ ] Fetch `origin`.
- [ ] Fast-forward local `main` to `origin/main`.
- [ ] Prove local `main` and `origin/main` have the same SHA.
- [ ] Build/test once more from the clean final `main` checkout.

### Gate 10 — deploy both stores

- [ ] Assign final v2.0.1 marketing/build/version codes in source.
- [ ] Upload and validate TestFlight; test the distributed build on the physical iPhone.
- [ ] Submit/release v2.0.1 to the Apple App Store and verify the resulting store state.
- [ ] Resolve Play service-account authorization with the user/admin.
- [ ] Upload the signed AAB, promote to the requested Play track, and verify rollout state.
- [ ] Confirm the store artifacts correspond to the final `origin/main` SHA.

### Gate 11 — cleanup only after deployment proof

- [ ] Close superseded PRs with links to the capturing mega commits.
- [ ] Delete merged/dead remote branches.
- [ ] Delete safe local branches.
- [ ] Remove obsolete worktrees after dirty/unpushed audits.
- [ ] Preserve deliberate submodule dirt and evidence archives.
- [ ] Finish on local `main`, clean except explicitly documented state, exactly matching `origin/main`.

## Definition of done

The v2.0.1 goal is complete only when all statements below are true:

- The same final SHA is on local `main`, `origin/main`, and both store release provenance records.
- Apple and Android unit/integration/UI suites are green.
- Physical iPhone and Android-device acceptance is green with recordings.
- Long-list navigation, session loading, conversation open/Back, composer typing, and multi-turn follow-ups meet the accepted performance thresholds without flicker.
- No required feature was removed or silently degraded.
- First-party tracked code is at least 25% below the frozen `origin/main` baseline.
- The signed release sizes and performance report are complete.
- Fable-5, GLM-5.3, and Claude Code Opus-5 blocking reviews are resolved.
- Apple App Store and Google Play both show the v2.0.1 release successfully deployed.
- Obsolete PRs, branches, and worktrees are removed only after provenance-safe capture.

Until then, status is **ACTIVE — NOT RELEASE READY**.
