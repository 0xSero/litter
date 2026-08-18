# Android QA Matrix

## Scope

This matrix covers transport reliability and startup-path parity for Android websocket + bridge flows.

## Automated Regression Scaffolding

Run the unit-test suite for the single hybrid runtime:

```bash
./gradlew :app:testDebugUnitTest
```

Current automated checks:

- `RuntimeFlavorConfigTest`
  - validates startup mode/build config parity (`ENABLE_ON_DEVICE_BRIDGE`, `RUNTIME_STARTUP_MODE`)
  - validates canonical app runtime transport declaration (`APP_RUNTIME_TRANSPORT`)
- `SavedServerTransportTest` and `SessionsDerivationTests`
  - validate persisted transport selection and session-list projection
- `AppComposerPayloadTest`, `SnapshotExtensionsTest`, and conversation UI tests
  - validate typed composer inputs, snapshot projection, markdown sizing, slash commands, math, and response errors
- `RealtimeWebRtcTransportTest` and `RealtimeWebRtcSessionTest`
  - validate the typed SDP transport and native WebRTC session lifecycle
- OAuth, server pairing, appearance, and home-dashboard tests
  - validate their platform adapters without duplicating the Rust reducer

## Manual Matrix

| Area | Hybrid runtime |
|---|---|
| App launch | App launches and can start a local bridge-backed session |
| Connect local/on-device | Success (`ServerConfig.local`) |
| Connect remote server | Success |
| Manual or saved SSH server | Prompts for SSH credentials, connects through SSH port forwarding, and never attempts `ws://host:22` directly |
| Local transport drop | Reconnect and one-time reinitialize before the next non-initialize RPC |
| Remote transport drop | Reconnect behavior via Rust `AppStore` updates and resumed RPC notifications |
| Thread start/resume fallback sandbox | `workspace-write` with `danger-full-access` fallback when Linux sandboxing is unavailable |
| Thread turn pagination (v0.125+ remote) | Conversation opens with the last 5 turns; "Load earlier messages" fetches older 5-turn pages via `thread/turns/list` |
| Thread turn pagination fallback (v0.124 remote) | Capability flips off via response inspection; embedded turns load fully; "Load earlier" is hidden |

## Terminal UX Matrix

The terminal screen renders through Ghostty on both platforms; this section
tracks parity between iOS (UIKit + Metal) and Android (Compose + SurfaceView).

| Area | iOS | Android |
|---|---|---|
| Full-screen surface | No bottom composer; the Ghostty surface fills the body | Same |
| Accessory bar | Esc/Tab/Ctrl/arrows/Paste/Clear/Send-to-AI dock above the keyboard via `inputAccessoryView` | Compose row anchored above the IME using `imePadding` |
| Tap-to-toggle keyboard | Single tap (no selection, no link) toggles the keyboard | Same |
| Long-press selection | Long-press seeds word selection; drag extends; handles paint via `TerminalSelectionOverlayView` | Long-press seeds word selection; drag extends; handles painted by a sibling Compose Canvas |
| Edit menu (Copy / Paste / Select All) | `UIEditMenuInteraction` anchored at the selection union rect | Compose floating action menu above the selection |
| Pinch-to-zoom font | `UIPinchGestureRecognizer` clamps to 10–24 pt and re-grids on settle | `ScaleGestureDetector` updates `TerminalConfigPrefs.fontSize` live and re-grids on scale-end |
| BEL haptic | `UIImpactFeedbackGenerator(.medium)` + system sound, throttled 250 ms | `performHapticFeedback(LONG_PRESS, IGNORE_VIEW_SETTING)`, throttled 250 ms |
| OSC8 hyperlink tap | Detected through Rust `linkAtPoint`; opens via `UIApplication.shared.open` | Detected through Rust `linkAtPoint`; opens via `Intent.ACTION_VIEW` |
| Cell-grid math | Driven by Ghostty `surfaceMetrics`; falls back to font-size-aware estimate on first frame | Same path via `nativeSurfaceSize` |
| Resize on rotation / keyboard show-hide | `layoutSubviews` plus `UIResponder.keyboardWillChangeFrame` triggers | `onSizeChanged` re-fires through Compose's `imePadding` insets |
| Mouse-tracking apps (vim / htop) | Single-finger drag forwards to Ghostty when `mouseCaptured` | Same |
| Alleycat remote host | Add Server's Kittylitter QR card opens `AlleycatAddServerSheet`; CameraX + ML Kit scan parses the Alleycat payload via `AlleycatBridge.parsePairPayload`; debug builds expose paste-JSON path; after token-authenticated pairing the sheet calls `serverBridge.listAlleycatAgents`, lets the user choose Codex/Pi/OpenCode, connects with `serverBridge.connectRemoteOverAlleycat`, and persists the token through `AlleycatCredentialStore`; `SavedServerStore.rememberAlleycat` writes `{node_id, relay?, agent}` records, reconnect attaches the encrypted-store token directly, and legacy Alleycat records require a new QR scan. | Same |
| Local Studio host (pairing) | Add Server → **Local Studio** opens the pairing sheet in Local Studio mode. Scanning the QR from Local Studio's Profile → Phone connection, or pasting its Copy connection JSON, saves a server with id `alleycat:local-studio:<nodeId>` and forces a new QR scan if the keychain/prefs entry is missing. | **Verified 2026-07-30 on an API 36 ARM64 emulator.** Copy-connection pairing reached the live Local Studio relay; the shared parser now normalizes the trailing dot emitted by the relay hostname, and the freshly signed release APK reconnected the saved pairing after reinstall. |
| Local Studio host (runtime) | Selecting Local Studio launches the shared Pi bridge against Local Studio's own `pi-agent` home, so the standard model selector, chat/tool timeline, and remote filesystem UI are reused. Permission controls are hidden because the runtime is fixed full-access. | **Verified 2026-07-30 on an API 36 ARM64 emulator.** The signed `1.6.0` release APK connected, resumed and hydrated Local Studio threads, and displayed the completed `ANDROID_LOCAL_STUDIO_OK` turn. The transport proof suite also passed all 11 scenarios, including command output, filesystem access, mid-turn status, reconnect, and final hydration. |

## Plugin `@`-mention parity (follow-up)

iOS ships `@plugin` mentions in the composer: typing `@` now lists installed
Codex plugins above the file results, selecting one inserts an `@<name>`
chip and emits an `AppUserInput.Mention { name, path }` item on
`turn/start`. Path encoding lives in shared Rust (`PluginSummary` UniFFI
record + `list_plugins` on `AppClient`).

Android does not have an `@`-trigger composer popup yet (no inline
`@<file>` autocomplete either), so plugin mentions are a follow-up. The
shared Rust client and the `AppUserInput.Mention` variant are already
wired through the Kotlin bindings, so the platform side just needs a
composer popup, chip row, and send-time append. Track this alongside the
broader composer autocomplete work.

## Suggested Smoke Steps

1. `debug`: connect the local default server, start a thread, send a turn, toggle network off/on, then send another turn.
2. `debug`: force-stop the app, relaunch, and confirm initialization and the thread list recover.
3. `debug`: connect a remote server and run `thread/list` plus `turn/start`.
4. Verify account read/login status refresh still updates UI after reconnect.

## Thinking-indicator Minigame (iOS + Android)

Gated by Settings → Experimental → "Thinking minigame" (off by default on
both platforms). The shimmering "Thinking..." indicator becomes tappable
while the assistant is generating; tapping it spins up an ephemeral thread
on `gpt-5.3-codex-spark` (low reasoning, fast tier) and renders the
returned `show_widget` HTML in a bottom-40% overlay that hides the
composer.

| Check | iOS | Android |
|---|---|---|
| Indicator is non-interactive when flag off | "Thinking" shimmer has no tap effect | Shimmer has no clickable ripple |
| Tap while thinking opens overlay immediately | Slides in with skeleton | Slides in with skeleton |
| Skeleton swaps to rendered widget on completion | WidgetWebView (no zoom, theme-injected) | MinigameWebView (no zoom, themed) |
| Composer is hidden while overlay is up | `ConversationBottomChrome` returns `EmptyView` from `safeAreaInset` | Composer `Column` is omitted |
| Last message is not occluded | safeAreaInset reserves overlay height in scroll inset | LazyColumn has trailing spacer / overlay sits over nav bar inset |
| Close (X) restores composer + idles overlay | `dismissMinigame()` cancels in-flight task | `dismissMinigame()` cancels coroutine |
| Repeat tap on a fresh assistant turn generates a new game | New ephemeral thread per request | New ephemeral thread per request |
| Bridge globals stubbed in minigame mode | `WKUserScript` at `.atDocumentStart` no-ops `sendPrompt`/`saveAppState`/`loadAppState`/`structuredResponse`, and the matching `WKScriptMessageHandler` registrations are skipped | `evaluateJavascript` in `onPageStarted` injects stubs; the matching `@JavascriptInterface` registrations are skipped (`WidgetBridge` for openLink/height/ready only) |
| Light + dark mode rendering | Widget uses host CSS variables that adapt automatically | Same |
| Minigame is NOT saved as a regular widget | Waiter intercepts `show_widget` so `auto_upsert_saved_app` is skipped, and `start_minigame` does not call `saved_app_upsert` itself | Same — single shared Rust path |
| Ephemeral thread is torn down | `thread/archive` after waiter resolves or times out | Same |
| Generation timeout (~30s) | Overlay shows failure card with "Try again" | Overlay shows failure card with "Try again" |

## Settings — Server Connection Editor (iOS + Android)

Tapping a saved server row in Settings opens the inline editor. Local servers are
name-only; alleycat-paired servers are name-only; everything else allows
mode + host/port/wake-MAC + URL editing. Save persists, Save & Reconnect
disconnects and re-establishes the chosen transport.

| Check | iOS | Android |
|---|---|---|
| Tap saved server row opens editor | `SettingsServerSheet.edit` opens `SettingsServerConnectionEditor` form sheet | Tap or row-menu "Edit" opens `ServerEditSheet` ModalBottomSheet |
| Local server: only name editable | Editor displays "managed automatically" copy; only Save & Restart action shown | Same — `ServerEditSheet` shows the same copy and uses "Save & Restart" |
| Alleycat-paired server: only name editable | Editor shows paired-pairing-metadata copy; mode picker hidden | Same — mode picker hidden, message visible |
| Switch to Direct Codex + Save & Reconnect | Persists, disconnects, calls `serverBridge.connectRemoteServer` | Same — `reconnectController.reconnectServer` reconnects via persisted record |
| Switch to WebSocket + Save & Reconnect | Persists, disconnects, calls `serverBridge.connectRemoteUrlServer` with `ws://` or `wss://` | Same — record stores `websocketURL`; reconnect dispatches via Rust `ReconnectController` |
| Switch to SSH + Save & Reconnect | Persists, dismisses editor, opens `SSHLoginSheet`; connect uses `serverBridge.startRemoteOverSshConnect` | Persists, dismisses editor, opens shared `SSHLoginDialog`; connect uses `serverBridge.startRemoteOverSshConnect` |
| Validation errors surface inline | Alert "Invalid Server" with localized reason, dismiss returns to editor | Same — `AlertDialog` with reason; dismiss returns to editor |
| Save (no reconnect) | Persists `SavedServerStore` + calls `store.renameServer`, leaves connection intact | Same |
| Remove server | `SavedServerStore.remove` + closes SSH session + disconnects bridge | Same |

## Sidebar + Picker Parity Checklist (iOS + Android)

### Session Sidebar

**Unreachable — do not QA until re-wired.** Android's `SessionsScreen` (search,
server filter, forks filter, lineage chips) is still compiled but `Route.Sessions`
is never constructed, so no user path opens it. iOS has no sidebar either; the
home dashboard replaced it. Treat this section as a parked feature, not a
shipping surface.

### Thread List Consistency

- Refresh (`thread/list`) prunes non-authoritative placeholder threads unless they are currently active.
- Notification-only placeholder rows disappear on next refresh once inactive.
- No regressions in thread switching, forking, or session search after placeholder pruning.

### Directory Picker

- Primary action: one-tap `Continue in <last folder>` appears when recents exist.
- Top controls remain visible while list scrolls: connected server chip/status + search.
- Breadcrumb + `Up one level` navigation always reflects current path.
- Bottom CTA is sticky and mirrors path state: `Select <path>` (or disabled helper text).
- Error state exposes both `Retry` and `Change server`.
- `Clear recent directories` requires destructive confirmation.
- Back behavior parity:
  - Android: `Back` navigates up before dismissing sheet.
- iOS: dismiss is blocked while not at root; cancel navigates up first.

### Appearance

- Chat wallpaper can be chosen from the photo library, persists across relaunch, and can be removed from Settings.
- Conversation screen and appearance preview both render the selected wallpaper instead of the fallback theme gradient.

### Conversation Selection

- Settled assistant markdown supports long-press selection/copy.
- Reasoning text supports long-press selection/copy.
- Command output supports selection/copy and still scrolls vertically.
- Error text supports selection/copy.
- Code blocks support selection/copy and still scroll horizontally.
- Markdown links remain tappable after selection support changes.

## Home Dashboard Zoom + Swipe Reply Parity (mirrors iOS b96961b3 + 52ff299d)

Ported in parallel with the iOS "new ui" and "new ui stuff" commits. Each
item must render identically to the iOS `HomeDashboardView` on zoom-1/2/3/4
for the matching state.

| Feature | Check |
|---|---|
| Zoom toolbar button | Top-right of header cycles 1→2→3→4→3→2→1 with icon matching level (ViewQuilt→ViewList→ViewAgenda→ViewStream). Persists across app restart via `DashboardZoomPrefs` SharedPreferences. |
| Pinch-to-zoom | Pinch on home LazyColumn crosses level thresholds (`pinchAccumulator ± 0.4 → 1 level`), emits haptic on transition, does not steal single-finger vertical scroll. |
| Zoom 1 (scan) | Title + StatusDot only; no meta/body/chips. |
| Zoom 2 (glance) | + time · server · workspace meta line. Tool-activity label + pulsing dots appear only when `isActive && isToolCallRunning(hydratedItems)` — pure thinking falls through to server metadata. |
| Zoom 3 (read) | + modelBadgeLine (server icon + server + model + fork/subagent) with trailing inline stats, + user-message quote `>` prefix, + compact tool log (1 row), + response preview capped at 25% screen. |
| Zoom 4 (deep) | Tool log expands to 3 rows; response preview cap rises to 50% screen; preview scroll-anchors to bottom when overflowing. |
| Response preview crossfade | New assistant-block id flip triggers Crossfade on the preview; preserved on empty new-turn assistant items via `displayedAssistantMessage` walking back to last non-empty. |
| TurnStopwatchChip | Live 1Hz tick while turn active (end=null) via `produceState` + `delay(1000)`; static elapsed when ended. Format `<60s → "Xs"`, `<3600s → "Xm" or "XmYs"`. |
| Tool log grouping | Consecutive exploration commands (read/search/listFiles `HydratedCommandActionKind`) collapse into `⌕ Explored N files, M searches, K listings` summary row; other tool kinds render as single-line rows. |
| inlineStats chips | Turn count, tool count, diff `+N/-N`, TurnStopwatchChip, token % (warning tint ≥80%). Left text truncates first; chips stay pinned. |
| recentUserMessage | `>` chip prefix + FormattedText at `LitterFont.conversationBodyPointSize × textScale`. Only shown when message exists and differs from title. |
| StatusDot shimmer | Active state gets both the 800ms alpha pulse AND a 2s linear-gradient sweep overlay. |
| Home hydration | Home list calls `appModel.externalResumeThread(session.key)` — not `client.readThread` — so the server attaches a live listener and cards update without opening the thread. |
| Swipe reply | Right-swipe on home row reveals reply affordance (`SessionReplySwipe` via `SwipeableRow.leadingAction`); past commit threshold opens `QuickReplySheet` modal; send path resumes the thread before `startTurn` to avoid "thread cannot be found" on cold launches. Left-swipe reveals hide (trailingAction). |
| SavedProjectStore | Last-selected server + project persist across app restart via Rust `preferencesSetHomeSelection` / `HomeSelection`. Wired through `LitterApp.kt`. |
| StreamingMarkdownView bodySize | Optional `bodySize` parameter thread through to TextView font size; opt-in by response preview and by direct consumers that need parametric sizing. |

## Tool Call Card Parity Matrix (iOS + Android)

Renderer contract for this release:

- default collapsed for tool cards, except `failed` cards (default expanded)
- header order: icon, summary/title, spacer, status chip, optional duration chip, chevron
- section order: metadata KV, payload sections (`Command/Arguments/Result/Output/Action`), auxiliary sections (`Prompt/Targets/Progress`)
- parse miss fallback: legacy markdown rendering unchanged

| Tool kind | Summary rule | Status chip | Expected sections |
|---|---|---|---|
| Command Execution | stripped command + status/duration suffix | `inProgress`/`completed`/`failed`/`unknown` | Metadata, Command, Output (if present), Progress (if present) |
| Command Output | output label fallback (`Command Output`) when no command | usually `unknown` | Output text/code |
| File Change | first basename + `+N files` | normalized from `Status:` | Metadata, repeated `Change N` metadata + diff/text content |
| File Diff | first path basename when available, else `File Diff` | usually `unknown` | Diff panel |
| MCP Tool Call | `Tool:` value + status suffix/check | normalized from `Status:` | Metadata, Arguments/Result, Error/Progress as available |
| MCP Tool Progress | tool/status fallback or title | usually `unknown` unless merged into MCP call | Progress timeline text |
| Web Search | `Query:` value | usually `unknown` | Metadata, Action JSON |
| Collaboration | `Tool:` value fallback | normalized from `Status:` | Metadata, Prompt text, Targets list |
| Image View | basename from `Path:` | usually `unknown` | Metadata (`Path`) |

Status normalization parity:

- `inProgress`, `in progress`, `running`, `pending`, `started` -> in progress (amber)
- `completed`, `complete`, `success`, `ok`, `done` -> completed (green)
- `failed`, `failure`, `error`, `denied`, `cancelled`, `aborted` -> failed (red)
- anything else/missing -> unknown (neutral)

## Saved Apps (Generative UI persistent apps)

Generative UI is permanent (no flag). Local-server threads register `show_widget` / `visualize_read_me`; remote-server threads do not. Saved apps are created automatically whenever a local-server model finalizes a `show_widget` with an `app_id` slug — there is no manual "Save as App" button.

| Area | Check |
|---|---|
| Bootstrap | `AppClient.setSavedAppsDirectory(MobilePreferencesDirectory.path(context))` is called once in `AppModel.init`, before any thread starts. Without this, the Rust `show_widget` finalize hook is a silent no-op. |
| Auto-upsert | When the model finalizes a `show_widget` with `app_id = "fitness-tracker"` on a local-server thread, the Rust hook calls `saved_app_upsert(directory, originThreadId, appId, title, html, w, h, schema)` and writes to `{filesDir}/LitterPreferences/apps/saved_apps.json` + `html/<uuid>.html`. No Kotlin-initiated promote call is needed. |
| Saved-as chip | Finalized `WidgetRow` whose `HydratedWidgetData.appId` is non-null renders a compact "Saved as `<slug>`" chip below the WebView (11sp mono, accent slug). Tap resolves `SavedAppsStore.appForSlug(slug, threadId)` to a UUID and pushes `Route.SavedApp`. Chip is absent when `appId == null` or the widget isn't finalized. |
| Home-row takeover | **Not wired.** `HomeDashboardScreen` builds a `savedAppsByThread` map keyed by `originThreadId` (reloaded via `SavedAppsStore.reload` on every snapshot tick) and a per-session `sessionApps` list, but the row always renders `SessionCanvasRow`. `HomeAppTakeoverRow` exists and is never called. Saved apps are reachable only via the Saved-as chip and the Apps list. |
| Apps list entry | Settings sheet "Apps → Saved Apps" row is always visible (no flag gate). Pushes `Route.Apps`. |
| Apps list | `AppsListScreen` renders apps newest-updated-first: monogram tile + title + relative timestamp. Swipe-to-dismiss cascades `savedAppDelete`. Empty state explains that saved apps are created automatically. |
| Detail relaunch | Tapping a row (or a Saved-as chip, or a home-row takeover) pushes `Route.SavedApp(uuid)`. `SavedAppScreen` calls `savedAppGet(dir, uuid)` on enter, hydrates the WebView with `wrapWidgetHtml(html, AppStateInjection(stateJson, schemaVersion))`, and registers `__LitterAppBridge` via `addJavascriptInterface`. |
| State persistence | `window.saveAppState(obj)` flows through the bridge into `SavedAppsStore.saveState`, 250 ms trailing-edge debounced per `appId`, landing in `savedAppSaveState`. `SavedAppException.StateTooLarge` logs + swallows. |
| Structured response | `window.structuredResponse({prompt, responseFormat})` returns a Promise that resolves with parsed JSON. Routes through `__LitterAppBridge.structuredResponse(requestId, prompt, schemaJson)` → `AppClient.structuredResponse` on an ephemeral hidden thread (`ThreadStartParams.ephemeral = true`). First call per view session creates the hidden thread; subsequent calls reuse it via `remember(appId) { mutableStateOf<String?>(null) }`. Reply flows back via `webView.evaluateJavascript("window.__resolveStructuredResponse(...)")`. Navigating away + returning resets the cache so a fresh ephemeral thread is created. The hidden thread never appears in the thread list (ephemeral threads are absent from `thread/list`). |
| Cold-launch persistence | Increment a counter in a saved app, `am force-stop`, relaunch, reopen the app. `loadAppState()` pulls `window._initialAppState` from the seeded state JSON — count survives. |
| Update flow | "Update" in the top bar opens `SavedAppUpdateOverlay`. Submit calls `SavedAppsStore.requestUpdate(...)` → `AppClient.updateSavedApp(...)`. WebView dims + shimmer overlay. On success: dismiss + detail re-fetch (state preserved because `replace_html` doesn't touch `state/<id>.json`). Failure: retry inline + toast. |
| Origin server routing | Update RPC prefers `originThreadId`'s server → active thread's server → any local server → any connected. No connected server → clear error message. |
| View Conversation | Top bar has a chat-bubble icon (`Icons.AutoMirrored.Filled.Chat`) that pushes `Route.Conversation(originThreadKey)`. Only rendered when `originThreadId` still resolves to a `ThreadKey` in the current snapshot — gone otherwise. |
| Rename / delete | Top bar title tap → rename dialog → `savedAppRename`. Overflow "Delete" → destructive confirmation → `savedAppDelete` → pop back to list. |
| Same slug in two threads | Model emitting `app_id = "fitness-tracker"` in two different origin threads creates two independent saved apps (distinct UUIDs, separate state files). The Apps list shows both; home-row takeover on each thread points at its own. |
| Regression: timeline widgets with no slug | A `show_widget` call that omits `app_id` (or is pre-R2) renders with the baseline `wrapWidgetHtml(html)` shell, does not trigger auto-save, and shows no Saved-as chip. |
| Regression: thread delete | Deleting an `originThreadId` thread does not affect saved apps; the `View Conversation` button becomes hidden for those apps but update/state flows still work. |

## Timeline WebView shell (SW-A0)

The timeline widget WebView shell (`wrapWidgetHtml` in `ConversationTimeline.kt`) is kept at parity with iOS's `WidgetWebView.buildShellHTML`. The shell is loaded **once** per WebView; subsequent content changes push through `window._setContent(html)` / `window._runScripts()` via `evaluateJavascript`, never a full page reload. This is the foundation for SW-A1 (partial widget-HTML streaming) and the fix for the prior "widgets pop in" behavior.

| Area | Check |
|---|---|
| Shell parity | `wrapWidgetHtml` emits the full iOS-parity document: theme vars in `:root`, `@keyframes _fadeIn` + `onNodeAdded` fade-in hook, morphdom CDN (`morphdom@2.7.4/dist/morphdom-umd.min.js`), and the `_morphReady` / `_pending` / `_setContent` / `_runScripts` / `_reportHeight` / `_attachHeightObserver` / `sendPrompt` / `openLink` JS. App-mode injection splices before `window._morphReady = false;`. |
| Bridge | JS posts `{_type, ...}` messages through `__postWidgetMessage`, which routes: `saveAppState` → `__LitterAppBridge`, `height`/`sendPrompt`/`openLink`/`ready` → `__LitterWidgetBridge`, with the iOS `webkit.messageHandlers.widget` fallback (no-op on Android). Both bridges coexist on the saved-app WebView. |
| Shell loads once | `AndroidView.factory` calls `loadDataWithBaseURL(..., wrapWidgetHtml(""), ...)` exactly once. `WebViewClient.onPageFinished` flips a per-WebView `widget_webview_shell_ready` tag to `true` and flushes any buffered HTML through `pushWidgetContent`. |
| Content push | Subsequent HTML changes in `AndroidView.update` call `pushWidgetContent(webView, html, runScripts = isFinalized)`, which runs `webView.evaluateJavascript("window._setContent('${escaped}'); window._runScripts();", null)`. `escapeJsString` matches iOS's `escapeJS` (backslash, single-quote, newline, CR, `</script>` → `<\/script>`). |
| Pre-ready queue | HTML changes that arrive before `onPageFinished` are stored on the WebView via the `widget_webview_pending_html` tag; `onPageFinished` flushes them. No content is dropped. |
| Dynamic height | `__LitterWidgetBridge.height(px)` posts the reported height through a main-thread `Handler`, clamped to `[200dp, 720dp]`. Compose's `mutableStateOf<Dp>(initial)` drives the WebView's `.height(widgetHeight)` modifier and animates smoothly as the widget grows/shrinks. Initial seed is the declared `data.height`. |
| sendPrompt | A widget button that calls `window.sendPrompt(text)` routes through `__LitterWidgetBridge.sendPrompt` → `onWidgetPrompt` callback in `WidgetRow` → `ConversationScreen` builds an `AppComposerPayload` and calls `appModel.startTurn(threadKey, payload)` — parity with iOS's `sendWidgetPrompt` which also submits a turn immediately. |
| openLink | Widget call to `window.openLink(url)` routes through the bridge to an `Intent.ACTION_VIEW` in the host Activity, opening the URL in the default browser. |
| Save-as-App bubble | `show_widget` finalize → auto-save (Rust-side) → Saved-as chip appears under the WebView. Shell lifecycle unchanged. |
| Saved app detail | `SavedAppScreen` uses the same shell through `wrapWidgetHtml("", AppStateInjection(...))` loaded once, then pushes `payload.widgetHtml` via `pushWidgetContent`. `loadAppState`/`saveAppState` still work. State persists across cold relaunch. |
| Regression: finalized timeline widget | An existing finalized `show_widget` renders identically to pre-refactor — fade-in animation, tap routing, state persistence of saved-app mode all preserved. |

## Realtime Voice (WebRTC transport)

Replaces the prior WebSocket + base64-PCM audio pump with a platform-native WebRTC peer connection on both iOS and Android. Upstream `thread/realtime/start` receives a client offer SDP via `AppRealtimeStartTransport.Webrtc`; the app-server responds with an answer SDP via `ThreadRealtimeSdpNotification`. All other realtime notifications (transcripts, item-added, handoff, closed, error) continue over the existing RPC WebSocket — only the audio byte path moved to the peer connection.

| Area | iOS | Android |
|---|---|---|
| Start request carries Webrtc transport | `AppStartRealtimeSessionRequest.transport == .webrtc(sdp:)` with a non-empty offer SDP (log at session start) | Same — `AppRealtimeStartTransport.Webrtc(sdp)` |
| Answer SDP applied | `AppStoreUpdateRecord.realtimeSdp` → `RealtimeWebRtcSession.applyAnswer(_:)` → `setRemoteDescription` succeeds | `AppStoreUpdateRecord.RealtimeSdp` → `RealtimeWebRtcSession.applyAnswer` → `setRemoteDescription` succeeds |
| Peer connection reaches connected state | `RTCPeerConnectionState.connected` observed via delegate | `PeerConnection.IceConnectionState.CONNECTED` observed |
| Bidirectional audio | Assistant voice plays back; mic input produces responses | Same |
| Transcript deltas (RPC path) | `ThreadRealtimeTranscriptDelta`/`Done` notifications still render | Same |
| Client-controlled handoff during voice | `HandoffManager` receives `HandoffRequested`, `resolveHandoff` / `finalizeHandoff` round-trip completes | Same |
| Dynamic tool call during voice | Argument deltas stream via RPC `ConversationItemAdded`; tool output returns via `resolveHandoff` | Same |
| Session stop | `RealtimeWebRtcSession.stop()` closes peer + data channel, deactivates `RTCAudioSession` | `stop()` disposes peer, restores audio mode, abandons audio focus |
| Session cycle (start/stop x5) | No leaked peer connections, microphone releases between sessions | No leaked peer, mic indicator clears between sessions |
| Known non-blockers | Per-frame input/output meter animation no longer drives — requires `RTCRtpReceiver.stats` polling to restore (follow-up) | Same flat meter behavior; speaker toggle currently stubbed to a boolean — follow-up to honor runtime routing |
| Regression: custom AEC path | Retired — `codex-ios-audio` crate + `AecBridge.swift` / `VoiceSessionAudioCodec.swift` were deleted; libwebrtc AEC3 handles echo cancellation natively | Retired — `AecBridge.kt` deleted; `JavaAudioDeviceModule` enables the hardware AEC + NS |
| Regression: SSH-tunneled codex server | RPC still flows through SSH; WebRTC peer goes direct to OpenAI edge from device. If client runs in fully air-gapped network, realtime voice will not establish | Same |
