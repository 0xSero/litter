# Codex submodule patches

Patches applied to `shared/third_party/codex` by `apps/ios/scripts/sync-codex.sh` during build.

The patches are tightly coupled to the upstream codex source tree, so each codex tag bump tends to require a refresh. This README captures *intent* — what each patch does and which downstream code in this repo depends on it — so the next bump doesn't have to re-derive that from a 900-line diff.

When a patch fails to apply, prefer `git apply --3way` first (handles line-number drift). If that conflicts on real semantic changes, refresh the affected hunks against the new upstream by editing the file directly, regenerating the patch with `git diff HEAD -- <file>`, and verifying with `git -C shared/third_party/codex apply --reverse --check`.

---

## `ios-exec-hook.patch`
Lets iOS install a function pointer that core's exec layer calls instead of `fork+exec` (forbidden in the App Store sandbox), and lets Android install an argv[0] resolver that maps `git` etc. to bundled `lib<tool>.so` paths in the app's nativeLibraryDir. Also installs an argv preflight that rewrites `/tmp/...` paths to the platform's real tempdir.

Touches `core/src/exec.rs` and `core/src/unified_exec/process_manager.rs`.

Consumed by `shared/rust-bridge/codex-mobile-client/src/ish_exec.rs` (`set_ios_exec_hook`), `android_exec.rs` (`set_android_tool_resolver`), and `shell_preflight.rs` (`set_mobile_exec_preflight`).

## `mobile-code-mode-stub.patch`
Replaces the V8 JavaScript runtime in `code-mode` with a stub on iOS, Android, and Linux. Mobile builds can't link `v8` (binary size, JIT entitlements), and the stub returns "exec is unavailable on mobile targets in this build" when invoked.

Touches `code-mode/Cargo.toml`, `code-mode/src/lib.rs`, adds `code-mode/src/runtime_stub.rs` and `service_stub.rs`.

When upstream changes the `runtime` or `service` API surface, audit the stubs to keep their type signatures in sync with the live (non-mobile) versions.

## `thread-read-permissions.patch`
Adds `approval_policy` and `sandbox` to `ThreadReadResponse` so mobile clients can render the live permission state of a thread without doing a separate config fetch.

Touches `app-server-protocol/src/protocol/v2/thread.rs` and `app-server/src/request_processors/thread_processor.rs`.

## `mobile-shell-snapshot-timeout.patch`
Drops the shell-snapshot timeout from 10s → 2s on iOS/Android. The mobile shell environment is minimal and snapshot probes nearly always time out at the upstream default, adding 10s to every thread start.

Touches `core/src/shell_snapshot.rs`.

## `remote-app-server-websocket-cap.patch`
Generalizes the remote app-server transport so it can drive any `AsyncRead + AsyncWrite` stream (not just `MaybeTlsStream<TcpStream>`). Required so that a single SSH connection can multiplex multiple websocket-style RPC sessions through litter's tunneling.

Touches `app-server-client/src/remote.rs`.

Consumed by `shared/rust-bridge/codex-mobile-client/src/ssh_remote_transport.rs`.

## `absolute-path-cross-platform.patch`
Lets `AbsolutePathBuf` deserialize Windows-style absolute paths on POSIX (and vice versa) without trying to canonicalize them through `path_absolutize::Absolutize` (which would mangle them by joining onto a POSIX cwd). Required because litter mobile clients consume thread metadata from servers running on either OS.

Touches `utils/absolute-path/src/lib.rs`.

## `android-installation-id-lock.patch`
Skip `File::lock()` on Android when persisting the installation id. Android's libstd returns `Unsupported` for that syscall, but the mobile app is the sole consumer of app-private storage so the lock isn't load-bearing.

Touches `core/src/installation_id.rs`.

## `dynamic-tool-call-arguments-delta.patch`
Adds streaming delta notifications for dynamic tool-call argument JSON. The model emits `response.function_call_arguments.delta` SSE events; this patch surfaces them as `EventMsg::DynamicToolCallArgumentsDelta` and `ServerNotification::DynamicToolCallArgumentsDelta` so mobile clients can render partial tool-call output before the call finalizes.

Touches `protocol/src/protocol.rs`, `app-server-protocol/src/protocol/{common.rs,event_mapping.rs,v2/item.rs}`, `app-server/src/bespoke_event_handling.rs`, `codex-api/src/sse/responses.rs`, `core/src/session/turn.rs`, `mcp-server/src/codex_tool_runner.rs`, `rollout-trace/src/protocol_event.rs`, `rollout/src/policy.rs`, `tui/src/{app/app_server_event_targets.rs,chatwidget.rs}`.

The TUI hunks are no-op match arms required only because upstream's `ServerNotification` matches are exhaustive.

## `realtime-webrtc-env-apikey.patch`
For WebRTC realtime sessions, populate the request headers with the API key obtained from `realtime_api_key(auth, provider)`. Without this, the WebRTC peer connection fails to authenticate when the user is signed in via env-key auth.

Touches `core/src/realtime_conversation.rs`.

---

## Realtime multi-server orchestrator (3 patches)

These three patches together let mobile clients (litter) own dynamic-tool execution and handoff resolution during a realtime audio session, instead of routing everything through the in-process background_agent. They were originally one monolithic patch (`client-controlled-handoff.patch`) but were split for easier maintenance — most upstream churn in the realtime layer affects only one of them.

Apply order in `sync-codex.sh` matters: `server-hint` first because it introduces the `realtime_v2_session_tools` helper that `dynamic-tools` reuses.

### `realtime-handoff-server-hint.patch`
Adds `server: Option<String>` to `RealtimeHandoffRequested` so the model can specify which connected server (e.g. `studio`, `mac-mini`, `local`) should handle the prompt. The mobile client reads this hint to route the handoff over SSH/WS to the right backend.

Touches `protocol/src/protocol.rs`, `codex-api/src/endpoint/realtime_websocket/{protocol_v1.rs,protocol_v2.rs}`, `app-server/src/bespoke_event_handling.rs`.

Deliberately does NOT touch `methods_v2.rs` — the `server` parameter on the `background_agent` tool schema is added by `realtime-dynamic-tools.patch` as part of the `realtime_v2_session_tools` helper extraction. This keeps patch #1 orthogonal to patch #2's hunks so each patch's reverse-apply detection works independently after upstream bumps.

Consumed by `shared/rust-bridge/codex-mobile-client/src/session/voice_handoff.rs::resolve_target_server` (which dispatches based on the `server` hint).

### `realtime-dynamic-tools.patch`
Lets the client inject arbitrary function tools into the realtime session and route their invocations back to the client over the existing `DynamicToolCall` server-request flow.

- Adds `dynamic_tools: Option<Vec<DynamicToolSpec>>` to `ConversationStartParams`, `ThreadRealtimeStartParams`, and `RealtimeSessionConfig`.
- Adds `RealtimeEvent::ToolCallRequested(Value)` for completed `function_call` items whose name is not `background_agent`.
- Routes those through `bespoke_event_handling.rs` to the existing `ServerRequestPayload::DynamicToolCall` flow.
- Adds `Op::RealtimeResolveDynamicTool { call_id, output }` and `HandoffOutput::DynamicToolOutput` to push the result back to the realtime API as `function_call_output` followed by `response.create`.
- Owns ALL `methods_v2.rs` changes: extracts `realtime_v2_session_tools(dynamic_tools: Option<Vec<DynamicToolSpec>>)` as a helper, adds the required `server` param to the `background_agent` schema (consumed by patch #1's `server` field), and replaces the inline `vec![...]` with a helper call.

Touches `protocol/src/protocol.rs`, `app-server-protocol/src/protocol/v2/realtime.rs`, `app-server/src/{bespoke_event_handling.rs,request_processors/turn_processor.rs}`, `codex-api/src/endpoint/realtime_websocket/{methods.rs,methods_common.rs,methods_v2.rs,protocol.rs,protocol_v2.rs}`, `core/src/{realtime_conversation.rs,session/handlers.rs}`.

Reuses upstream's existing `RealtimeWebsocketWriter::send_conversation_function_call_output` rather than introducing a parallel V2 helper.

Consumed by `shared/rust-bridge/codex-mobile-client/src/session/voice_handoff.rs::voice_dynamic_tools()` (defines the `list_servers` and `list_sessions` tools).

### `realtime-client-controlled-handoff.patch`
When `client_controlled_handoff: true`, suppresses upstream's automatic "route handoff to background agent" path in `handle_start_inner` so the client can resolve the handoff its own way (e.g., dispatching to a remote server over SSH).

- Adds `client_controlled_handoff: bool` to `ConversationStartParams` and `ThreadRealtimeStartParams`.
- Adds RPCs `thread/realtime/resolveHandoff` (sends `function_call_output` for the active handoff but does NOT trigger `response.create`) and `thread/realtime/finalizeHandoff` (separately fires `response.create` so the client can stream multiple resolves before the model speaks).
- Adds the corresponding `Op::RealtimeConversationResolveHandoff` and `Op::RealtimeConversationFinalizeHandoff`.
- Plumbs a `finalize_tx`/`finalize_rx` async channel into `RealtimeInputChannels` so finalize signals reach `run_realtime_input_task`'s `tokio::select!` from outside the input task.

Touches `protocol/src/protocol.rs`, `app-server-protocol/src/protocol/{common.rs,v2/realtime.rs}`, `app-server/src/{message_processor.rs,request_processors.rs,request_processors/turn_processor.rs}`, `core/src/{realtime_conversation.rs,session/handlers.rs}`.

Consumed by `shared/rust-bridge/codex-mobile-client/src/session/voice_handoff.rs::HandoffManager` and the iOS/Android `VoiceRuntimeController`s, which use `HandoffAction::ResolveHandoff` and `HandoffAction::FinalizeHandoff` to drive the resolution flow.
