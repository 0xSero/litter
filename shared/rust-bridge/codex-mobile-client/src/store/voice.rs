use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::types::ThreadKey;
use crate::types::{AppVoiceHandoffRequest, AppVoiceSpeaker, AppVoiceTranscriptUpdate};

#[derive(Debug, Clone)]
pub enum VoiceDerivedUpdate {
    Transcript(AppVoiceTranscriptUpdate),
    HandoffRequest(AppVoiceHandoffRequest),
    SpeechStarted,
}

#[derive(Default)]
pub struct VoiceRealtimeState {
    threads: Mutex<HashMap<ThreadKey, VoiceRealtimeThreadState>>,
}

#[derive(Default)]
struct VoiceRealtimeThreadState {
    next_virtual_id: u64,
    pending_user_item_id: Option<String>,
    pending_assistant_item_id: Option<String>,
    live_user_text: String,
    live_assistant_text: String,
    last_delta: Option<LastDelta>,
}

struct LastDelta {
    speaker: AppVoiceSpeaker,
    delta: String,
    timestamp: Instant,
}

impl VoiceRealtimeState {
    pub fn reset_thread(&self, key: &ThreadKey) {
        self.threads
            .lock()
            .expect("voice state lock poisoned")
            .insert(key.clone(), VoiceRealtimeThreadState::default());
    }

    pub fn clear_thread(&self, key: &ThreadKey) {
        self.threads
            .lock()
            .expect("voice state lock poisoned")
            .remove(key);
    }

    /// Handle a typed transcript delta directly (from upstream
    /// `ThreadRealtimeTranscriptUpdated` notification).
    pub fn handle_typed_transcript_delta(
        &self,
        key: &ThreadKey,
        role: &str,
        text: &str,
    ) -> Vec<VoiceDerivedUpdate> {
        let speaker = if role == "user" {
            AppVoiceSpeaker::User
        } else {
            AppVoiceSpeaker::Assistant
        };
        let mut threads = self.threads.lock().expect("voice state lock poisoned");
        let thread = threads.entry(key.clone()).or_default();
        thread.handle_transcript_delta_str(text, speaker)
    }

    pub fn handle_item(
        &self,
        key: &ThreadKey,
        item: &serde_json::Value,
    ) -> Vec<VoiceDerivedUpdate> {
        let mut threads = self.threads.lock().expect("voice state lock poisoned");
        let thread = threads.entry(key.clone()).or_default();
        thread.handle_item(item)
    }
}

impl VoiceRealtimeThreadState {
    fn handle_item(&mut self, item: &serde_json::Value) -> Vec<VoiceDerivedUpdate> {
        let item_type = item
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        match item_type {
            "handoff_request" => {
                vec![VoiceDerivedUpdate::HandoffRequest(AppVoiceHandoffRequest {
                    handoff_id: str_for_keys(item, &["handoff_id", "handoffId", "id"])
                        .unwrap_or_else(|| self.next_virtual_item_id("handoff")),
                    input_transcript: str_for_keys(item, &["input_transcript", "inputTranscript"])
                        .unwrap_or_default(),
                    active_transcript: parse_active_transcript(item),
                    server_hint: str_for_keys(item, &["server_hint", "serverHint", "server"]),
                    fallback_transcript: str_for_keys(
                        item,
                        &["fallback_transcript", "fallbackTranscript"],
                    ),
                })]
            }
            "message" => self.handle_message_item(item),
            "input_transcript_delta" => self.handle_transcript_delta(item, AppVoiceSpeaker::User),
            "output_transcript_delta" => {
                self.handle_transcript_delta(item, AppVoiceSpeaker::Assistant)
            }
            "speech_started" | "input_audio_buffer.speech_started" => {
                let mut updates = Vec::new();
                if let Some(update) = self.flush_live_transcript(AppVoiceSpeaker::Assistant) {
                    updates.push(update);
                }
                self.pending_user_item_id = None;
                self.live_user_text.clear();
                updates.push(VoiceDerivedUpdate::SpeechStarted);
                updates
            }
            _ => Vec::new(),
        }
    }

    fn handle_message_item(&mut self, item: &serde_json::Value) -> Vec<VoiceDerivedUpdate> {
        let role = item
            .get("role")
            .and_then(|v| v.as_str())
            .unwrap_or("assistant");
        let speaker = if role == "user" {
            AppVoiceSpeaker::User
        } else {
            AppVoiceSpeaker::Assistant
        };
        let previous_speaker = match speaker {
            AppVoiceSpeaker::User => AppVoiceSpeaker::Assistant,
            AppVoiceSpeaker::Assistant => AppVoiceSpeaker::User,
        };
        let upstream_item_id = item.get("id").and_then(|v| v.as_str()).map(String::from);
        let text = parse_message_text(item);
        let mut updates = Vec::new();

        if let Some(update) = self.flush_live_transcript(previous_speaker) {
            updates.push(update);
        }

        let display_item_id = self.resolve_display_item_id(
            speaker,
            upstream_item_id.as_deref(),
            !text.trim().is_empty(),
        );

        if text.trim().is_empty() {
            self.set_pending_item_id(speaker, Some(display_item_id));
            return updates;
        }

        let merged = merge_text(self.live_text(speaker), &text);
        self.set_live_text(speaker, String::new());
        self.set_pending_item_id(speaker, None);

        updates.push(VoiceDerivedUpdate::Transcript(AppVoiceTranscriptUpdate {
            item_id: display_item_id,
            speaker,
            text: merged,
            is_final: true,
        }));
        updates
    }

    fn handle_transcript_delta(
        &mut self,
        item: &serde_json::Value,
        speaker: AppVoiceSpeaker,
    ) -> Vec<VoiceDerivedUpdate> {
        let delta = item
            .get("delta")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        self.handle_transcript_delta_str(delta, speaker)
    }

    fn handle_transcript_delta_str(
        &mut self,
        delta: &str,
        speaker: AppVoiceSpeaker,
    ) -> Vec<VoiceDerivedUpdate> {
        if delta.is_empty() || self.should_skip_delta(delta, speaker) {
            return Vec::new();
        }

        let display_item_id = self.resolve_display_item_id(speaker, None, false);
        let merged = merge_text(self.live_text(speaker), delta);
        self.set_live_text(speaker, merged.clone());
        self.set_pending_item_id(speaker, Some(display_item_id.clone()));

        vec![VoiceDerivedUpdate::Transcript(AppVoiceTranscriptUpdate {
            item_id: display_item_id,
            speaker,
            text: merged,
            is_final: false,
        })]
    }

    fn should_skip_delta(&mut self, delta: &str, speaker: AppVoiceSpeaker) -> bool {
        let now = Instant::now();
        if let Some(previous) = &self.last_delta
            && previous.speaker == speaker
                && previous.delta == delta
                && now.duration_since(previous.timestamp) < Duration::from_millis(500)
            {
                return true;
            }
        self.last_delta = Some(LastDelta {
            speaker,
            delta: delta.to_string(),
            timestamp: now,
        });
        false
    }

    fn flush_live_transcript(&mut self, speaker: AppVoiceSpeaker) -> Option<VoiceDerivedUpdate> {
        let text = self.live_text(speaker).to_string();
        if text.is_empty() {
            return None;
        }
        let item_id = self.pending_item_id(speaker)?.clone();
        self.set_live_text(speaker, String::new());
        self.set_pending_item_id(speaker, None);
        Some(VoiceDerivedUpdate::Transcript(AppVoiceTranscriptUpdate {
            item_id,
            speaker,
            text,
            is_final: true,
        }))
    }

    fn next_virtual_item_id(&mut self, prefix: &str) -> String {
        let id = self.next_virtual_id;
        self.next_virtual_id += 1;
        format!("voice-{prefix}-{id}")
    }

    fn resolve_display_item_id(
        &mut self,
        speaker: AppVoiceSpeaker,
        upstream_item_id: Option<&str>,
        force_new: bool,
    ) -> String {
        if let Some(id) = upstream_item_id {
            self.set_pending_item_id(speaker, Some(id.to_string()));
            return id.to_string();
        }
        if !force_new
            && let Some(id) = self.pending_item_id(speaker) {
                return id.clone();
            }
        let label = match speaker {
            AppVoiceSpeaker::User => "user",
            AppVoiceSpeaker::Assistant => "assistant",
        };
        let new_id = self.next_virtual_item_id(label);
        self.set_pending_item_id(speaker, Some(new_id.clone()));
        new_id
    }

    fn pending_item_id(&self, speaker: AppVoiceSpeaker) -> Option<&String> {
        match speaker {
            AppVoiceSpeaker::User => self.pending_user_item_id.as_ref(),
            AppVoiceSpeaker::Assistant => self.pending_assistant_item_id.as_ref(),
        }
    }

    fn set_pending_item_id(&mut self, speaker: AppVoiceSpeaker, id: Option<String>) {
        match speaker {
            AppVoiceSpeaker::User => self.pending_user_item_id = id,
            AppVoiceSpeaker::Assistant => self.pending_assistant_item_id = id,
        }
    }

    fn live_text(&self, speaker: AppVoiceSpeaker) -> &str {
        match speaker {
            AppVoiceSpeaker::User => &self.live_user_text,
            AppVoiceSpeaker::Assistant => &self.live_assistant_text,
        }
    }

    fn set_live_text(&mut self, speaker: AppVoiceSpeaker, value: String) {
        match speaker {
            AppVoiceSpeaker::User => self.live_user_text = value,
            AppVoiceSpeaker::Assistant => self.live_assistant_text = value,
        }
    }
}

fn merge_text(existing: &str, incoming: &str) -> String {
    if existing.is_empty() {
        return incoming.to_string();
    }
    if existing == incoming || existing.ends_with(incoming) {
        return existing.to_string();
    }
    if incoming.starts_with(existing) {
        return incoming.to_string();
    }
    if existing.starts_with(incoming) {
        return existing.to_string();
    }
    format!("{existing}{incoming}")
}

fn parse_message_text(item: &serde_json::Value) -> String {
    item.get("content")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|part| {
            let t = part.get("type").and_then(|v| v.as_str())?;
            matches!(t, "text" | "input_text" | "output_text")
                .then(|| part.get("text").and_then(|v| v.as_str()).map(String::from))
                .flatten()
        })
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

fn parse_active_transcript(item: &serde_json::Value) -> String {
    let key = if item.get("active_transcript").is_some() {
        "active_transcript"
    } else {
        "activeTranscript"
    };

    let value = match item.get(key) {
        Some(v) => v,
        None => return String::new(),
    };

    if let Some(arr) = value.as_array() {
        let from_array: String = arr
            .iter()
            .filter_map(|entry| {
                let role = entry.get("role").and_then(|v| v.as_str())?;
                let text = entry.get("text").and_then(|v| v.as_str())?;
                Some(format!("{role}: {text}"))
            })
            .collect::<Vec<_>>()
            .join("\n");

        if !from_array.is_empty() {
            return from_array;
        }
    }

    value.as_str().unwrap_or_default().to_string()
}

fn str_for_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| value.get(*key)).and_then(|v| {
        v.as_str()
            .map(String::from)
            .or_else(|| v.as_i64().map(|n| n.to_string()))
            .or_else(|| v.as_u64().map(|n| n.to_string()))
            .or_else(|| v.as_f64().map(|n| n.to_string()))
            .or_else(|| v.as_bool().map(|b| b.to_string()))
    })
}

#[cfg(test)]
mod tests {
    use super::{VoiceDerivedUpdate, VoiceRealtimeState};
    use crate::types::ThreadKey;
    use serde_json::json;

    #[test]
    fn transcript_deltas_are_merged_and_deduped() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json!({"type": "input_transcript_delta", "delta": "Hel"}),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected transcript update");
        };
        assert_eq!(first.text, "Hel");
        assert!(!first.is_final);

        let updates = state.handle_item(
            &key,
            &json!({"type": "input_transcript_delta", "delta": "Hello"}),
        );
        let [VoiceDerivedUpdate::Transcript(second)] = updates.as_slice() else {
            panic!("expected merged transcript update");
        };
        assert_eq!(second.text, "Hello");

        let updates = state.handle_item(
            &key,
            &json!({"type": "input_transcript_delta", "delta": "Hello"}),
        );
        assert!(updates.is_empty());
    }

    #[test]
    fn final_message_prefers_upstream_item_id_when_available() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json!({"type": "output_transcript_delta", "delta": "Tool"}),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected transcript update");
        };

        let updates = state.handle_item(
            &key,
            &json!({
                "type": "message",
                "role": "assistant",
                "id": "item_123",
                "content": [{"type": "text", "text": "Tool result"}]
            }),
        );
        let [VoiceDerivedUpdate::Transcript(second)] = updates.as_slice() else {
            panic!("expected final message update");
        };
        assert_eq!(first.item_id, "voice-assistant-0");
        assert_eq!(second.item_id, "item_123");
        assert_eq!(second.text, "Tool result");
        assert!(second.is_final);
    }

    #[test]
    fn final_user_message_accepts_input_text_content_with_upstream_id() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json!({"type": "input_transcript_delta", "delta": "Hello"}),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected transcript update");
        };

        let updates = state.handle_item(
            &key,
            &json!({
                "type": "message",
                "role": "user",
                "id": "item_user_123",
                "content": [{"type": "input_text", "text": "Hello there"}]
            }),
        );
        let [VoiceDerivedUpdate::Transcript(second)] = updates.as_slice() else {
            panic!("expected final user message update");
        };
        assert_eq!(first.item_id, "voice-user-0");
        assert_eq!(second.item_id, "item_user_123");
        assert_eq!(second.speaker, crate::types::AppVoiceSpeaker::User);
        assert_eq!(second.text, "Hello there");
        assert!(second.is_final);
    }

    #[test]
    fn final_assistant_message_accepts_output_text_content_with_upstream_id() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json!({"type": "output_transcript_delta", "delta": "Hi"}),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected transcript update");
        };

        let updates = state.handle_item(
            &key,
            &json!({
                "type": "message",
                "role": "assistant",
                "id": "item_assistant_123",
                "content": [{"type": "output_text", "text": "Hi there"}]
            }),
        );
        let [VoiceDerivedUpdate::Transcript(second)] = updates.as_slice() else {
            panic!("expected final assistant message update");
        };
        assert_eq!(first.item_id, "voice-assistant-0");
        assert_eq!(second.item_id, "item_assistant_123");
        assert_eq!(second.speaker, crate::types::AppVoiceSpeaker::Assistant);
        assert_eq!(second.text, "Hi there");
        assert!(second.is_final);
    }

    #[test]
    fn switching_speakers_flushes_previous_live_transcript() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json!({"type": "input_transcript_delta", "delta": "Search docs"}),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected live user transcript");
        };
        assert!(!first.is_final);

        let updates = state.handle_item(
            &key,
            &json!({
                "type": "message",
                "role": "assistant",
                "id": "item_assistant_456",
                "content": [{"type": "output_text", "text": "Looking now"}]
            }),
        );
        assert_eq!(updates.len(), 2);
        let VoiceDerivedUpdate::Transcript(flushed_user) = &updates[0] else {
            panic!("expected flushed user transcript");
        };
        let VoiceDerivedUpdate::Transcript(assistant_final) = &updates[1] else {
            panic!("expected assistant final transcript");
        };
        assert_eq!(flushed_user.speaker, crate::types::AppVoiceSpeaker::User);
        assert_eq!(flushed_user.text, "Search docs");
        assert!(flushed_user.is_final);
        assert_eq!(
            assistant_final.speaker,
            crate::types::AppVoiceSpeaker::Assistant
        );
        assert_eq!(assistant_final.text, "Looking now");
        assert!(assistant_final.is_final);
    }

    #[test]
    fn handoff_request_is_normalized() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };
        let updates = state.handle_item(
            &key,
            &json!({
                "type": "handoff_request",
                "handoff_id": "handoff-1",
                "input_transcript": "Search docs",
                "active_transcript": [{"role": "user", "text": "Search docs"}],
                "server_hint": "remote"
            }),
        );
        let [VoiceDerivedUpdate::HandoffRequest(request)] = updates.as_slice() else {
            panic!("expected handoff request");
        };
        assert_eq!(request.handoff_id, "handoff-1");
        assert_eq!(request.input_transcript, "Search docs");
        assert_eq!(request.active_transcript, "user: Search docs");
        assert_eq!(request.server_hint.as_deref(), Some("remote"));
    }

    #[test]
    fn speech_started_aliases_emit_same_update() {
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let legacy_state = VoiceRealtimeState::default();
        let legacy = legacy_state.handle_item(&key, &json!({"type": "speech_started"}));
        assert!(matches!(
            legacy.as_slice(),
            [VoiceDerivedUpdate::SpeechStarted]
        ));

        let upstream_state = VoiceRealtimeState::default();
        let upstream =
            upstream_state.handle_item(&key, &json!({"type": "input_audio_buffer.speech_started"}));
        assert!(matches!(
            upstream.as_slice(),
            [VoiceDerivedUpdate::SpeechStarted]
        ));
    }
}
