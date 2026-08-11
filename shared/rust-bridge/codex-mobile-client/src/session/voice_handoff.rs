//! Voice handoff orchestration: cross-server tool routing during realtime sessions.
//!
//! This module owns:
//! - HandoffManager: the handoff state machine, transcript delta buffering,
//!   tool-result text accumulation, thread-reuse mapping, and the
//!   stream-items-to-handoff polling logic
//!
//! The audio pipeline (AVAudioEngine) and Live Activity updates remain on
//! the Swift side.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::types::models::ThreadKey;

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

/// Phase of a single handoff.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HandoffPhase {
    /// Handoff received, waiting for thread creation / reuse.
    Pending = 0,
    /// Thread obtained, turn sent — streaming remote items.
    Streaming = 1,
    /// All items streamed, waiting for finalization RPC.
    WaitingFinalize = 2,
    /// Handoff fully resolved.
    Completed = 3,
    /// An error occurred.
    Failed = 4,
}

/// Identifies a connected remote server.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectedServer {
    pub server_id: String,
    pub name: String,
    pub hostname: String,
    pub is_local: bool,
    pub is_connected: bool,
}

/// A single streamed text chunk from a remote thread item.
#[derive(Debug, Clone, uniffi::Record)]
pub struct StreamedItem {
    pub item_id: String,
    pub text: String,
}

/// Accumulated transcript from delta events.
#[derive(Debug, Clone, Default)]
pub struct TranscriptBuffer {
    pub text: String,
    pub speaker: Option<String>,
}

/// Configuration for a handoff turn (model/effort overrides).
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct HandoffTurnConfig {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub fast_mode: bool,
}

/// State for a single in-flight handoff.
#[derive(Debug, Clone)]
pub struct HandoffEntry {
    pub handoff_id: String,
    pub phase: HandoffPhase,
    /// The voice session thread (local).
    pub voice_thread_key: ThreadKey,
    /// Target server ID for this handoff.
    pub target_server_id: Option<String>,
    /// Target server display name.
    pub target_server_name: String,
    /// Whether the target is the local server.
    pub is_local_target: bool,
    /// The transcript / prompt to send.
    pub transcript: String,
    /// The remote thread used for this handoff (filled after thread creation).
    pub remote_thread_key: Option<ThreadKey>,
    /// Base item count at the time the turn was sent.
    pub base_item_count: usize,
    /// Items that have been streamed to the realtime session.
    pub sent_texts: HashMap<String, String>,
    /// Last observed item signature from platform polling.
    pub last_stream_signature: Option<String>,
    /// Number of consecutive inactive polls with a stable item signature.
    pub stable_inactive_polls: u8,
    /// Error message if failed.
    pub error: Option<String>,
    /// When the streaming phase started.
    pub stream_start: Option<Instant>,
    /// Timeout for the streaming phase in seconds.
    pub stream_timeout_secs: u64,
}

// ---------------------------------------------------------------------------
// Actions — what the platform layer should do next
// ---------------------------------------------------------------------------

/// An action the platform layer must perform on behalf of the Rust handoff manager.
/// After performing the action, the platform calls back to report the result.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum HandoffAction {
    /// Start or reuse a thread on the target server.
    StartThread {
        handoff_id: String,
        target_server_id: String,
        is_local: bool,
        cwd: String,
    },
    /// Send a turn on the remote thread.
    SendTurn {
        handoff_id: String,
        target_server_id: String,
        thread_id: String,
        transcript: String,
        config: HandoffTurnConfig,
    },
    /// Resolve the handoff with output text (stream a chunk).
    ResolveHandoff {
        handoff_id: String,
        voice_thread_key: ThreadKey,
        text: String,
    },
    /// Finalize the handoff (no more chunks).
    FinalizeHandoff {
        handoff_id: String,
        voice_thread_key: ThreadKey,
    },
    /// Update UI: set the handoff item's thread key.
    UpdateHandoffItem {
        handoff_id: String,
        voice_thread_key: ThreadKey,
        remote_thread_key: ThreadKey,
    },
    /// Update UI: mark the handoff item as completed.
    CompleteHandoffItem {
        handoff_id: String,
        voice_thread_key: ThreadKey,
    },
    /// Set the voice session phase.
    SetVoicePhase {
        phase_name: String, // "listening", "handoff", "error"
    },
    /// Report an error.
    Error { handoff_id: String, message: String },
}

// ---------------------------------------------------------------------------
// HandoffManager
// ---------------------------------------------------------------------------

/// Central manager for cross-server handoff routing during voice sessions.
///
/// Thread-safe: all mutation goes through the inner `Mutex`.
#[derive(uniffi::Object)]
pub struct HandoffManager {
    inner: Mutex<HandoffManagerInner>,
}

struct HandoffManagerInner {
    /// Connected servers (server_id → info).
    servers: HashMap<String, ConnectedServer>,
    /// Active handoffs (handoff_id → entry).
    handoffs: HashMap<String, HandoffEntry>,
    /// Reusable thread per server (server_id → ThreadKey). Persists across
    /// handoffs within a voice session so the remote agent accumulates context.
    reused_threads: HashMap<String, ThreadKey>,
    /// Pending actions for the platform to execute.
    action_queue: Vec<HandoffAction>,
    /// Turn config overrides.
    turn_config: HandoffTurnConfig,
    /// Transcript delta buffer.
    transcript: TranscriptBuffer,
    /// Local server ID constant.
    local_server_id: String,
}

impl HandoffManager {
    pub fn new(local_server_id: &str) -> Self {
        Self {
            inner: Mutex::new(HandoffManagerInner {
                servers: HashMap::new(),
                handoffs: HashMap::new(),
                reused_threads: HashMap::new(),
                action_queue: Vec::new(),
                turn_config: HandoffTurnConfig::default(),
                transcript: TranscriptBuffer::default(),
                local_server_id: local_server_id.to_string(),
            }),
        }
    }

    // -- Server registry --

    pub fn register_server(&self, server: ConnectedServer) {
        let mut inner = self.inner.lock().unwrap();
        inner.servers.insert(server.server_id.clone(), server);
    }

    pub fn unregister_server(&self, server_id: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.servers.remove(server_id);
    }

    pub fn set_turn_config(&self, config: HandoffTurnConfig) {
        let mut inner = self.inner.lock().unwrap();
        inner.turn_config = config;
    }

    // -- Transcript buffering --

    /// Accumulate a transcript delta. Returns the new full text and whether
    /// the speaker changed (meaning the previous text should be flushed).
    pub fn accumulate_transcript_delta(
        &self,
        delta: &str,
        speaker: &str,
    ) -> (String, Option<String>, bool) {
        let mut inner = self.inner.lock().unwrap();
        let speaker_changed = inner.transcript.speaker.as_deref() != Some(speaker);
        let previous_text = if speaker_changed {
            let prev = inner.transcript.text.clone();
            inner.transcript.text = delta.to_string();
            inner.transcript.speaker = Some(speaker.to_string());
            if prev.trim().is_empty() {
                None
            } else {
                Some(prev)
            }
        } else {
            inner.transcript.text.push_str(delta);
            None
        };
        let full_text = inner.transcript.text.clone();
        (full_text, previous_text, speaker_changed)
    }

    /// Drain the transcript buffer, returning any accumulated text and speaker.
    pub fn drain_transcript(&self) -> (Option<String>, Option<String>) {
        let mut inner = self.inner.lock().unwrap();
        let text = if inner.transcript.text.trim().is_empty() {
            None
        } else {
            Some(std::mem::take(&mut inner.transcript.text))
        };
        let speaker = inner.transcript.speaker.take();
        (text, speaker)
    }

    // -- Handoff lifecycle --

    /// Process an incoming `handoff_request` item from the realtime session.
    /// Resolves the target server and enqueues the initial action.
    pub fn handle_handoff_request(
        &self,
        handoff_id: &str,
        voice_thread_key: ThreadKey,
        input_transcript: &str,
        active_transcript: &str,
        server_hint: Option<&str>,
        fallback_transcript: Option<&str>,
    ) {
        let mut inner = self.inner.lock().unwrap();

        let transcript = if !active_transcript.is_empty() {
            active_transcript.to_string()
        } else if !input_transcript.is_empty() {
            input_transcript.to_string()
        } else {
            fallback_transcript.unwrap_or("").to_string()
        };

        // Resolve target server.
        let (target_server_id, target_name, is_local) =
            resolve_target_server(&inner.servers, &inner.local_server_id, server_hint);

        let entry = HandoffEntry {
            handoff_id: handoff_id.to_string(),
            phase: HandoffPhase::Pending,
            voice_thread_key: voice_thread_key.clone(),
            target_server_id: target_server_id.clone(),
            target_server_name: target_name.clone(),
            is_local_target: is_local,
            transcript: transcript.clone(),
            remote_thread_key: None,
            base_item_count: 0,
            sent_texts: HashMap::new(),
            last_stream_signature: None,
            stable_inactive_polls: 0,
            error: None,
            stream_start: None,
            stream_timeout_secs: 120,
        };

        inner.handoffs.insert(handoff_id.to_string(), entry);

        // Enqueue phase transition.
        inner.action_queue.push(HandoffAction::SetVoicePhase {
            phase_name: "handoff".to_string(),
        });

        if let Some(ref server_id) = target_server_id {
            // Check if we have a reusable thread.
            if let Some(reused) = inner.reused_threads.get(server_id).cloned() {
                // Skip thread creation — report thread directly.
                if let Some(entry) = inner.handoffs.get_mut(handoff_id) {
                    entry.remote_thread_key = Some(reused.clone());
                }
                inner.action_queue.push(HandoffAction::UpdateHandoffItem {
                    handoff_id: handoff_id.to_string(),
                    voice_thread_key: voice_thread_key.clone(),
                    remote_thread_key: reused.clone(),
                });
                let config = inner.turn_config.clone();
                inner.action_queue.push(HandoffAction::SendTurn {
                    handoff_id: handoff_id.to_string(),
                    target_server_id: server_id.clone(),
                    thread_id: reused.thread_id.clone(),
                    transcript,
                    config,
                });
            } else {
                let cwd = if is_local {
                    "/".to_string()
                } else {
                    let srv = inner.servers.get(server_id);
                    let hostname = srv.map(|s| s.hostname.as_str()).unwrap_or("remote");
                    if hostname == "localhost" {
                        "/".to_string()
                    } else {
                        "/tmp".to_string()
                    }
                };
                inner.action_queue.push(HandoffAction::StartThread {
                    handoff_id: handoff_id.to_string(),
                    target_server_id: server_id.clone(),
                    is_local,
                    cwd,
                });
            }
        } else {
            // No matching server — resolve with error.
            let msg = format!("Server '{}' is not available.", target_name);
            inner.action_queue.push(HandoffAction::ResolveHandoff {
                handoff_id: handoff_id.to_string(),
                voice_thread_key: voice_thread_key.clone(),
                text: msg.clone(),
            });
            inner.action_queue.push(HandoffAction::FinalizeHandoff {
                handoff_id: handoff_id.to_string(),
                voice_thread_key,
            });
            if let Some(entry) = inner.handoffs.get_mut(handoff_id) {
                entry.phase = HandoffPhase::Failed;
                entry.error = Some(msg);
            }
        }
    }

    /// Report that a thread was created (or reused) for a handoff.
    pub fn report_thread_created(&self, handoff_id: &str, thread_key: ThreadKey) {
        let mut inner = self.inner.lock().unwrap();

        // Extract all needed values from the entry first to avoid borrow conflicts.
        let (voice_key, transcript, target_server_id) = {
            let entry = match inner.handoffs.get_mut(handoff_id) {
                Some(e) => e,
                None => return,
            };
            entry.remote_thread_key = Some(thread_key.clone());
            (
                entry.voice_thread_key.clone(),
                entry.transcript.clone(),
                entry.target_server_id.clone(),
            )
        };

        // Cache for reuse.
        if let Some(ref server_id) = target_server_id {
            inner
                .reused_threads
                .insert(server_id.clone(), thread_key.clone());
        }

        inner.action_queue.push(HandoffAction::UpdateHandoffItem {
            handoff_id: handoff_id.to_string(),
            voice_thread_key: voice_key,
            remote_thread_key: thread_key.clone(),
        });

        // Now send the turn.
        let config = inner.turn_config.clone();
        inner.action_queue.push(HandoffAction::SendTurn {
            handoff_id: handoff_id.to_string(),
            target_server_id: target_server_id.unwrap_or_default(),
            thread_id: thread_key.thread_id,
            transcript,
            config,
        });
    }

    /// Report that a thread creation failed.
    pub fn report_thread_creation_failed(&self, handoff_id: &str, error: &str) {
        let mut inner = self.inner.lock().unwrap();
        let voice_key = {
            let entry = match inner.handoffs.get_mut(handoff_id) {
                Some(e) => e,
                None => return,
            };
            entry.phase = HandoffPhase::Failed;
            entry.error = Some(error.to_string());
            entry.voice_thread_key.clone()
        };
        let msg = format!("Failed to start thread: {}", error);
        inner.action_queue.push(HandoffAction::ResolveHandoff {
            handoff_id: handoff_id.to_string(),
            voice_thread_key: voice_key.clone(),
            text: msg,
        });
        inner.action_queue.push(HandoffAction::FinalizeHandoff {
            handoff_id: handoff_id.to_string(),
            voice_thread_key: voice_key,
        });
    }

    /// Report that the turn was sent and streaming should begin.
    pub fn report_turn_sent(&self, handoff_id: &str, base_item_count: usize) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(entry) = inner.handoffs.get_mut(handoff_id) {
            entry.phase = HandoffPhase::Streaming;
            entry.base_item_count = base_item_count;
            entry.stream_start = Some(Instant::now());
        }
    }

    /// Report that the turn send failed.
    pub fn report_turn_send_failed(&self, handoff_id: &str, error: &str) {
        let mut inner = self.inner.lock().unwrap();
        let voice_key = {
            let entry = match inner.handoffs.get_mut(handoff_id) {
                Some(e) => e,
                None => return,
            };
            entry.phase = HandoffPhase::Failed;
            entry.error = Some(error.to_string());
            entry.voice_thread_key.clone()
        };
        let msg = format!("Failed to send turn: {}", error);
        inner.action_queue.push(HandoffAction::ResolveHandoff {
            handoff_id: handoff_id.to_string(),
            voice_thread_key: voice_key.clone(),
            text: msg,
        });
        inner.action_queue.push(HandoffAction::FinalizeHandoff {
            handoff_id: handoff_id.to_string(),
            voice_thread_key: voice_key,
        });
    }

    /// Called periodically during the streaming phase with the current
    /// state of the remote thread. Returns actions to execute (stream chunks,
    /// finalize, etc.).
    ///
    /// `current_items`: items from the remote thread starting at base_item_count.
    /// `turn_active`: whether the remote turn is still running.
    pub fn poll_stream_progress(
        &self,
        handoff_id: &str,
        current_items: &[StreamedItem],
        turn_active: bool,
    ) {
        let mut inner = self.inner.lock().unwrap();

        // Collect actions in a local vec to avoid borrow conflicts.
        let mut new_actions: Vec<HandoffAction> = Vec::new();

        {
            let entry = match inner.handoffs.get_mut(handoff_id) {
                Some(e) if e.phase == HandoffPhase::Streaming => e,
                _ => return,
            };

            let voice_key = entry.voice_thread_key.clone();
            let stream_signature = stream_items_signature(current_items);
            let stream_changed =
                entry.last_stream_signature.as_deref() != Some(stream_signature.as_str());
            entry.last_stream_signature = Some(stream_signature);

            // Check timeout.
            if let Some(start) = entry.stream_start
                && start.elapsed() > Duration::from_secs(entry.stream_timeout_secs) {
                    entry.phase = HandoffPhase::WaitingFinalize;
                    if entry.sent_texts.is_empty() {
                        new_actions.push(HandoffAction::ResolveHandoff {
                            handoff_id: handoff_id.to_string(),
                            voice_thread_key: voice_key.clone(),
                            text: "(No response -- timed out)".to_string(),
                        });
                    }
                    new_actions.push(HandoffAction::FinalizeHandoff {
                        handoff_id: handoff_id.to_string(),
                        voice_thread_key: voice_key,
                    });
                    inner.action_queue.extend(new_actions);
                    return;
                }

            // V2 realtime treats progress updates as user conversation items.
            // Do not feed live background-agent progress back into realtime while
            // the turn is still active, or the voice agent will keep responding
            // to those updates as if the user had spoken.
            if turn_active {
                entry.stable_inactive_polls = 0;
                return;
            }

            if stream_changed {
                entry.stable_inactive_polls = 0;
                return;
            }

            entry.stable_inactive_polls = entry.stable_inactive_polls.saturating_add(1);
            if entry.stable_inactive_polls < 2 {
                return;
            }

            // Stream final items once the remote turn has been observed inactive
            // with a stable item set across consecutive polls.
            for item in current_items {
                if item.text.is_empty() {
                    continue;
                }
                if entry.sent_texts.get(&item.item_id).map(|s| s.as_str()) == Some(&item.text) {
                    continue;
                }

                entry
                    .sent_texts
                    .insert(item.item_id.clone(), item.text.clone());
                new_actions.push(HandoffAction::ResolveHandoff {
                    handoff_id: handoff_id.to_string(),
                    voice_thread_key: voice_key.clone(),
                    text: item.text.clone(),
                });
            }

            entry.phase = HandoffPhase::WaitingFinalize;
            if entry.sent_texts.is_empty() {
                new_actions.push(HandoffAction::ResolveHandoff {
                    handoff_id: handoff_id.to_string(),
                    voice_thread_key: voice_key.clone(),
                    text: "(No response)".to_string(),
                });
            }
            new_actions.push(HandoffAction::FinalizeHandoff {
                handoff_id: handoff_id.to_string(),
                voice_thread_key: voice_key,
            });
        }

        inner.action_queue.extend(new_actions);
    }

    /// Report that the finalization RPC succeeded.
    pub fn report_finalized(&self, handoff_id: &str) {
        let mut inner = self.inner.lock().unwrap();
        let voice_key = {
            let entry = match inner.handoffs.get_mut(handoff_id) {
                Some(e) => e,
                None => return,
            };
            entry.phase = HandoffPhase::Completed;
            entry.voice_thread_key.clone()
        };
        inner.action_queue.push(HandoffAction::CompleteHandoffItem {
            handoff_id: handoff_id.to_string(),
            voice_thread_key: voice_key,
        });
        inner.action_queue.push(HandoffAction::SetVoicePhase {
            phase_name: "listening".to_string(),
        });
    }

    // -- Action queue --

    /// Drain all pending actions.
    pub fn drain_actions(&self) -> Vec<HandoffAction> {
        let mut inner = self.inner.lock().unwrap();
        std::mem::take(&mut inner.action_queue)
    }

    /// Return the number of pending actions without draining.
    pub fn action_count(&self) -> usize {
        let inner = self.inner.lock().unwrap();
        inner.action_queue.len()
    }

    /// Get the current phase of a handoff.
    pub fn handoff_phase(&self, handoff_id: &str) -> Option<HandoffPhase> {
        let inner = self.inner.lock().unwrap();
        inner.handoffs.get(handoff_id).map(|e| e.phase)
    }

    /// Get the remote thread key for a handoff (for inline display).
    pub fn handoff_remote_thread_key(&self, handoff_id: &str) -> Option<ThreadKey> {
        let inner = self.inner.lock().unwrap();
        inner
            .handoffs
            .get(handoff_id)
            .and_then(|e| e.remote_thread_key.clone())
    }

    /// Get the reused thread for a server (if any).
    pub fn reused_thread(&self, server_id: &str) -> Option<ThreadKey> {
        let inner = self.inner.lock().unwrap();
        inner.reused_threads.get(server_id).cloned()
    }

    /// Clear all state (called when voice session ends).
    pub fn reset(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.handoffs.clear();
        inner.reused_threads.clear();
        inner.action_queue.clear();
        inner.transcript = TranscriptBuffer::default();
    }

    // -- Voice Handoff Tool Handlers (pure logic) --

    /// Build the server list response for the `list_servers` tool.
    pub fn list_servers_response(&self) -> String {
        let inner = self.inner.lock().unwrap();
        let items: Vec<serde_json::Value> = inner
            .servers
            .values()
            .map(|s| {
                serde_json::json!({
                    "name": if s.is_local { "local" } else { &s.name },
                    "hostname": &s.hostname,
                    "isConnected": s.is_connected,
                    "isLocal": s.is_local,
                })
            })
            .collect();
        let payload = serde_json::json!({ "type": "servers", "items": items });
        serde_json::to_string(&payload).unwrap_or_else(|_| "[]".to_string())
    }
}

// ---------------------------------------------------------------------------
// UniFFI-exported wrapper — converts &str→String, tuples→Records, usize→u32
// ---------------------------------------------------------------------------

/// Result from accumulate_transcript_delta (UniFFI doesn't support tuples).
#[derive(uniffi::Record)]
pub struct TranscriptDeltaResult {
    pub full_text: String,
    pub previous_text: Option<String>,
    pub speaker_changed: bool,
}

/// Result from drain_transcript.
#[derive(uniffi::Record)]
pub struct DrainTranscriptResult {
    pub text: Option<String>,
    pub speaker: Option<String>,
}

#[uniffi::export]
impl HandoffManager {
    #[uniffi::constructor]
    pub fn create(local_server_id: String) -> Self {
        Self::new(&local_server_id)
    }

    pub fn uniffi_register_server(
        &self,
        server_id: String,
        name: String,
        hostname: String,
        is_local: bool,
        is_connected: bool,
    ) {
        self.register_server(ConnectedServer {
            server_id,
            name,
            hostname,
            is_local,
            is_connected,
        });
    }

    pub fn uniffi_unregister_server(&self, server_id: String) {
        self.unregister_server(&server_id);
    }

    pub fn uniffi_set_turn_config(
        &self,
        model: Option<String>,
        effort: Option<String>,
        fast_mode: bool,
    ) {
        self.set_turn_config(HandoffTurnConfig {
            model,
            effort,
            fast_mode,
        });
    }

    pub fn uniffi_accumulate_transcript_delta(
        &self,
        delta: String,
        speaker: String,
    ) -> TranscriptDeltaResult {
        let (full_text, previous_text, speaker_changed) =
            self.accumulate_transcript_delta(&delta, &speaker);
        TranscriptDeltaResult {
            full_text,
            previous_text,
            speaker_changed,
        }
    }

    pub fn uniffi_drain_transcript(&self) -> DrainTranscriptResult {
        let (text, speaker) = self.drain_transcript();
        DrainTranscriptResult { text, speaker }
    }

    pub fn uniffi_handle_handoff_request(
        &self,
        handoff_id: String,
        voice_server_id: String,
        voice_thread_id: String,
        input_transcript: String,
        active_transcript: String,
        server_hint: Option<String>,
        fallback_transcript: Option<String>,
    ) {
        let voice_thread_key = ThreadKey {
            server_id: voice_server_id,
            thread_id: voice_thread_id,
        };
        self.handle_handoff_request(
            &handoff_id,
            voice_thread_key,
            &input_transcript,
            &active_transcript,
            server_hint.as_deref(),
            fallback_transcript.as_deref(),
        );
    }

    pub fn uniffi_report_thread_created(
        &self,
        handoff_id: String,
        server_id: String,
        thread_id: String,
    ) {
        let key = ThreadKey {
            server_id,
            thread_id,
        };
        self.report_thread_created(&handoff_id, key);
    }

    pub fn uniffi_report_thread_failed(&self, handoff_id: String, error: String) {
        self.report_thread_creation_failed(&handoff_id, &error);
    }

    pub fn uniffi_report_turn_sent(&self, handoff_id: String, base_item_count: u32) {
        self.report_turn_sent(&handoff_id, base_item_count as usize);
    }

    pub fn uniffi_report_turn_failed(&self, handoff_id: String, error: String) {
        self.report_turn_send_failed(&handoff_id, &error);
    }

    pub fn uniffi_poll_stream_progress(
        &self,
        handoff_id: String,
        items: Vec<StreamedItem>,
        turn_active: bool,
    ) {
        self.poll_stream_progress(&handoff_id, &items, turn_active);
    }

    pub fn uniffi_report_finalized(&self, handoff_id: String) {
        self.report_finalized(&handoff_id);
    }

    pub fn uniffi_drain_actions(&self) -> Vec<HandoffAction> {
        self.drain_actions()
    }

    pub fn uniffi_reset(&self) {
        self.reset();
    }

    pub fn uniffi_list_servers_json(&self) -> String {
        self.list_servers_response()
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn resolve_target_server(
    servers: &HashMap<String, ConnectedServer>,
    local_server_id: &str,
    server_hint: Option<&str>,
) -> (Option<String>, String, bool) {
    let hint = match server_hint {
        Some(h) if !h.is_empty() => h,
        _ => return (None, "unknown".to_string(), false),
    };

    if hint.eq_ignore_ascii_case("local") {
        if servers
            .get(local_server_id)
            .map(|s| s.is_connected)
            .unwrap_or(false)
        {
            return (Some(local_server_id.to_string()), "local".to_string(), true);
        }
        return (None, "local".to_string(), true);
    }

    for (id, srv) in servers {
        if !srv.is_local && srv.name.eq_ignore_ascii_case(hint) && srv.is_connected {
            return (Some(id.clone()), srv.name.clone(), false);
        }
    }

    (None, hint.to_string(), false)
}

fn stream_items_signature(items: &[StreamedItem]) -> String {
    let mut signature = String::new();
    for item in items {
        signature.push_str(&item.item_id);
        signature.push('\0');
        signature.push_str(&item.text);
        signature.push('\0');
    }
    signature
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- HandoffManager tests --

    #[test]
    fn test_basic_handoff_lifecycle() {
        let mgr = HandoffManager::new("local");

        mgr.register_server(ConnectedServer {
            server_id: "local".into(),
            name: "local".into(),
            hostname: "localhost".into(),
            is_local: true,
            is_connected: true,
        });
        mgr.register_server(ConnectedServer {
            server_id: "remote-1".into(),
            name: "devbox".into(),
            hostname: "devbox.example.com".into(),
            is_local: false,
            is_connected: true,
        });

        let voice_key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        mgr.handle_handoff_request(
            "handoff-1",
            voice_key.clone(),
            "please run tests on devbox",
            "",
            Some("devbox"),
            None,
        );

        let actions = mgr.drain_actions();
        assert!(actions.len() >= 2); // SetVoicePhase + StartThread

        let start = actions
            .iter()
            .find(|a| matches!(a, HandoffAction::StartThread { .. }));
        assert!(start.is_some());

        // Report thread created.
        let remote_key = ThreadKey {
            server_id: "remote-1".into(),
            thread_id: "remote-thread-1".into(),
        };
        mgr.report_thread_created("handoff-1", remote_key.clone());

        let actions = mgr.drain_actions();
        let send = actions
            .iter()
            .find(|a| matches!(a, HandoffAction::SendTurn { .. }));
        assert!(send.is_some());

        // Report turn sent.
        mgr.report_turn_sent("handoff-1", 0);
        assert_eq!(
            mgr.handoff_phase("handoff-1"),
            Some(HandoffPhase::Streaming)
        );

        // Poll with active items: no realtime action yet. Progress is visible
        // from the remote thread itself; feeding it into realtime as a user
        // message makes the voice agent respond repeatedly while work runs.
        let items = vec![StreamedItem {
            item_id: "item-1".into(),
            text: "Tests passed!".into(),
        }];
        mgr.poll_stream_progress("handoff-1", &items, true);
        assert!(mgr.drain_actions().is_empty());

        // A single inactive sample may be a stale snapshot. Require a stable
        // inactive sample before resolving/finalizing the handoff.
        mgr.poll_stream_progress("handoff-1", &items, false);
        assert!(mgr.drain_actions().is_empty());
        mgr.poll_stream_progress("handoff-1", &items, false);

        let actions = mgr.drain_actions();
        let resolve = actions
            .iter()
            .find(|a| matches!(a, HandoffAction::ResolveHandoff { .. }));
        assert!(resolve.is_some());
        let finalize = actions
            .iter()
            .find(|a| matches!(a, HandoffAction::FinalizeHandoff { .. }));
        assert!(finalize.is_some());

        // Report finalized.
        mgr.report_finalized("handoff-1");
        assert_eq!(
            mgr.handoff_phase("handoff-1"),
            Some(HandoffPhase::Completed)
        );

        // Thread should be reusable.
        assert_eq!(mgr.reused_thread("remote-1"), Some(remote_key));
    }

    #[test]
    fn test_transcript_buffering() {
        let mgr = HandoffManager::new("local");

        let (full, prev, changed) = mgr.accumulate_transcript_delta("Hello", "Codex");
        assert_eq!(full, "Hello");
        assert!(prev.is_none());
        assert!(changed); // first delta always changes speaker

        let (full, prev, changed) = mgr.accumulate_transcript_delta(" world", "Codex");
        assert_eq!(full, "Hello world");
        assert!(prev.is_none());
        assert!(!changed);

        let (full, prev, changed) = mgr.accumulate_transcript_delta("Hi", "You");
        assert_eq!(full, "Hi");
        assert_eq!(prev, Some("Hello world".to_string()));
        assert!(changed);
    }

    #[test]
    fn test_server_not_found() {
        let mgr = HandoffManager::new("local");

        let voice_key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        mgr.handle_handoff_request(
            "handoff-2",
            voice_key,
            "run something",
            "",
            Some("nonexistent"),
            None,
        );

        let actions = mgr.drain_actions();
        let resolve = actions
            .iter()
            .find(|a| matches!(a, HandoffAction::ResolveHandoff { text, .. } if text.contains("not available")));
        assert!(resolve.is_some());
        assert_eq!(mgr.handoff_phase("handoff-2"), Some(HandoffPhase::Failed));
    }

    #[test]
    fn test_list_servers_response() {
        let mgr = HandoffManager::new("local");
        mgr.register_server(ConnectedServer {
            server_id: "local".into(),
            name: "my-machine".into(),
            hostname: "localhost".into(),
            is_local: true,
            is_connected: true,
        });
        let json = mgr.list_servers_response();
        assert!(json.contains("\"name\":\"local\""));
        assert!(json.contains("\"isLocal\":true"));
    }
}
