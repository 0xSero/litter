use std::sync::Mutex;
use std::time::Instant;

use codex_app_server_protocol::{ClientRequest, ServerNotification};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordedEntry {
    pub ts_ms: u64,
    pub dir: Direction,
    pub server_id: String,
    pub json: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Direction {
    #[serde(rename = "in")]
    In,
    #[serde(rename = "out")]
    Out,
}

pub struct MessageRecorder {
    state: Mutex<RecorderState>,
}

struct RecorderState {
    is_recording: bool,
    start: Option<Instant>,
    entries: Vec<RecordedEntry>,
}

impl MessageRecorder {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(RecorderState {
                is_recording: false,
                start: None,
                entries: Vec::new(),
            }),
        }
    }

    pub fn start_recording(&self) {
        let mut s = self.state.lock().unwrap();
        s.entries.clear();
        s.start = Some(Instant::now());
        s.is_recording = true;
    }

    pub fn is_recording(&self) -> bool {
        self.state.lock().unwrap().is_recording
    }

    pub fn record_notification(&self, server_id: &str, notification: &ServerNotification) {
        let mut s = self.state.lock().unwrap();
        if !s.is_recording {
            return;
        }
        let ts_ms = s.start.map(|t| t.elapsed().as_millis() as u64).unwrap_or(0);
        if let Ok(json) = serde_json::to_string(notification) {
            s.entries.push(RecordedEntry {
                ts_ms,
                dir: Direction::In,
                server_id: server_id.to_string(),
                json,
            });
        }
    }

    pub fn record_request(&self, server_id: &str, request: &ClientRequest) {
        let mut s = self.state.lock().unwrap();
        if !s.is_recording {
            return;
        }
        let ts_ms = s.start.map(|t| t.elapsed().as_millis() as u64).unwrap_or(0);
        if let Ok(json) = serde_json::to_string(request) {
            s.entries.push(RecordedEntry {
                ts_ms,
                dir: Direction::Out,
                server_id: server_id.to_string(),
                json,
            });
        }
    }

    pub fn stop_recording(&self) -> String {
        let mut s = self.state.lock().unwrap();
        s.is_recording = false;
        s.start = None;
        let entries = std::mem::take(&mut s.entries);
        serde_json::to_string(&entries).unwrap_or_else(|_| "[]".to_string())
    }

    /// Replay inbound notifications from a recording, rewriting server/thread
    /// IDs so the updates land on the caller's active thread.
    pub fn replay_entries(
        data: &str,
        target_server_id: &str,
        target_thread_id: &str,
    ) -> Result<Vec<(u64, String, ServerNotification)>, String> {
        let entries: Vec<RecordedEntry> =
            serde_json::from_str(data).map_err(|e| format!("parse recording: {e}"))?;

        // Discover the original server_id and thread_id from the first inbound entry.
        let source_server_id = entries
            .iter()
            .find(|e| e.dir == Direction::In)
            .map(|e| e.server_id.clone());
        let source_thread_id = entries.iter().find_map(|e| {
            if e.dir != Direction::In {
                return None;
            }
            // Extract thread_id from the notification JSON params.
            let v: serde_json::Value = serde_json::from_str(&e.json).ok()?;
            v.get("params")
                .and_then(|p| p.get("threadId").or_else(|| p.get("thread_id")))
                .and_then(|t| t.as_str())
                .or_else(|| {
                    v.get("params")
                        .and_then(|p| p.get("thread"))
                        .and_then(|t| t.get("id"))
                        .and_then(|id| id.as_str())
                })
                .map(|s| s.to_string())
        });

        let mut result = Vec::new();
        for entry in entries {
            if entry.dir != Direction::In {
                continue;
            }
            // Rewrite IDs in the raw JSON before deserializing.
            let mut json = entry.json.clone();
            if let Some(ref src_tid) = source_thread_id {
                json = json.replace(src_tid, target_thread_id);
            }
            if let Some(ref src_sid) = source_server_id {
                // Only rewrite in the JSON payload, not the entry server_id.
                json = json.replace(src_sid, target_server_id);
            }
            match serde_json::from_str::<ServerNotification>(&json) {
                Ok(notification) => {
                    result.push((entry.ts_ms, target_server_id.to_string(), notification));
                }
                Err(e) => {
                    tracing::warn!("skip undeserializable recording entry: {e}");
                }
            }
        }
        Ok(result)
    }
}
