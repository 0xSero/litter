//! Litter-side JSON-line wire for the upstream `RemoteAppServerClient`.
//!
//! Upstream's `RemoteAppServerClient` only ships WebSocket transports (`connect`,
//! `connect_websocket_stream`). Pi/non-Codex servers and the SSH-bridge bootstrap path
//! talk plain JSON-RPC over a raw byte stream (one JSON object per line). The patch in
//! `patches/codex/remote-app-server-websocket-cap.patch` exposes a [`JsonRpcWire`] trait
//! and a public `RemoteAppServerClient::connect_with_wire` constructor so we can drive
//! the same dispatch loop over any wire. This module implements that wire for raw
//! line-delimited JSON-RPC and exposes a `connect_json_line_stream` helper to mirror
//! the upstream `connect_websocket_stream` API.
use std::io::{Error as IoError, Result as IoResult};

use codex_app_server_client::{JsonRpcWire, RemoteAppServerClient, RemoteAppServerConnectArgs};
use codex_app_server_protocol::JSONRPCMessage;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

/// Non-Codex bridges can intentionally trail the upstream app-server schema.
/// v0.129 made lifecycle timestamps mandatory; older Pi/Local Studio bridges
/// still emit otherwise-valid item notifications without them. Normalize at
/// the raw JSONL boundary, before `RemoteAppServerClient` strict-decodes and
/// silently drops the entire notification (including tool calls/results).
fn normalize_legacy_item_lifecycle_notification(value: &mut serde_json::Value) {
    let Some(message) = value.as_object_mut() else {
        return;
    };
    let timestamp_field = match message.get("method").and_then(serde_json::Value::as_str) {
        Some("item/started") => "startedAtMs",
        Some("item/completed") => "completedAtMs",
        _ => return,
    };
    let Some(params) = message
        .get_mut("params")
        .and_then(serde_json::Value::as_object_mut)
    else {
        return;
    };
    params
        .entry(timestamp_field.to_string())
        .or_insert_with(|| serde_json::Value::Number(0.into()));
    if let Some(item) = params
        .get_mut("item")
        .and_then(serde_json::Value::as_object_mut)
        && item.get("type").and_then(serde_json::Value::as_str) == Some("commandExecution")
        && item
            .get("cwd")
            .and_then(serde_json::Value::as_str)
            .is_none_or(str::is_empty)
    {
        // AbsolutePathBuf rejects the empty cwd emitted by older Pi bridges.
        item.insert("cwd".to_string(), serde_json::Value::String("/".to_string()));
    }
}

struct JsonLineWire<R, W> {
    reader: BufReader<R>,
    writer: W,
}

impl<R, W> JsonRpcWire for JsonLineWire<R, W>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    async fn send_message(
        &mut self,
        message: JSONRPCMessage,
        label: &str,
    ) -> IoResult<()> {
        let payload = serde_json::to_vec(&message).map_err(IoError::other)?;
        self.writer.write_all(&payload).await.map_err(|err| {
            IoError::other(format!(
                "failed to write JSON-lines message to `{label}`: {err}"
            ))
        })?;
        self.writer.write_all(b"\n").await.map_err(|err| {
            IoError::other(format!(
                "failed to finish JSON-lines message to `{label}`: {err}"
            ))
        })?;
        self.writer.flush().await.map_err(|err| {
            IoError::other(format!(
                "failed to flush JSON-lines message to `{label}`: {err}"
            ))
        })
    }

    async fn next_message(&mut self, label: &str) -> IoResult<Option<JSONRPCMessage>> {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).await.map_err(|err| {
            IoError::other(format!(
                "failed to read JSON-lines message from `{label}`: {err}"
            ))
        })?;
        if read == 0 {
            return Ok(None);
        }
        let mut value = serde_json::from_str::<serde_json::Value>(&line).map_err(|err| {
            IoError::other(format!(
                "remote app server at `{label}` sent invalid JSON-RPC: {err}"
            ))
        })?;
        normalize_legacy_item_lifecycle_notification(&mut value);
        serde_json::from_value::<JSONRPCMessage>(value)
            .map(Some)
            .map_err(|err| {
                IoError::other(format!(
                    "remote app server at `{label}` sent invalid JSON-RPC: {err}"
                ))
            })
    }

    async fn close(&mut self, label: &str) -> IoResult<()> {
        self.writer.shutdown().await.map_err(|err| {
            IoError::other(format!(
                "failed to close JSON-lines app server `{label}`: {err}"
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_legacy_item_lifecycle_notification;
    use codex_app_server_protocol::{JSONRPCMessage, ServerNotification};
    use serde_json::json;

    #[test]
    fn legacy_item_lifecycle_notifications_survive_strict_upstream_decode() {
        for (method, timestamp_field) in [
            ("item/started", "startedAtMs"),
            ("item/completed", "completedAtMs"),
        ] {
            let mut value = json!({
                "jsonrpc": "2.0",
                "method": method,
                "params": {
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "item": {
                        "type": "userMessage",
                        "id": "user-1",
                        "content": []
                    }
                }
            });
            normalize_legacy_item_lifecycle_notification(&mut value);
            assert_eq!(value["params"][timestamp_field], 0);
            let message: JSONRPCMessage = serde_json::from_value(value).expect("json-rpc");
            let JSONRPCMessage::Notification(notification) = message else {
                panic!("expected notification");
            };
            ServerNotification::try_from(notification)
                .expect("upstream should accept normalized lifecycle notification");
        }
    }

    #[test]
    fn explicit_lifecycle_timestamp_is_never_overwritten() {
        let mut value = json!({
            "jsonrpc": "2.0",
            "method": "item/completed",
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "completedAtMs": 42,
                "item": { "type": "userMessage", "id": "user-1", "content": [] }
            }
        });
        normalize_legacy_item_lifecycle_notification(&mut value);
        assert_eq!(value["params"]["completedAtMs"], 42);
    }

    #[test]
    fn legacy_command_item_with_empty_cwd_survives_strict_upstream_decode() {
        let mut value = json!({
            "jsonrpc": "2.0",
            "method": "item/completed",
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "item": {
                    "type": "commandExecution",
                    "id": "command-1",
                    "command": "printf OK",
                    "cwd": "",
                    "source": "agent",
                    "status": "completed",
                    "commandActions": [],
                    "aggregatedOutput": "OK"
                }
            }
        });
        normalize_legacy_item_lifecycle_notification(&mut value);
        assert_eq!(value["params"]["item"]["cwd"], "/");
        let message: JSONRPCMessage = serde_json::from_value(value).expect("json-rpc");
        let JSONRPCMessage::Notification(notification) = message else {
            panic!("expected notification");
        };
        ServerNotification::try_from(notification)
            .expect("upstream should accept normalized command lifecycle notification");
    }
}

/// Connect a [`RemoteAppServerClient`] over an arbitrary line-delimited JSON-RPC
/// stream. Mirrors the API shape of upstream's `connect_websocket_stream`.
pub async fn connect_json_line_stream<S>(
    stream: S,
    args: RemoteAppServerConnectArgs,
    label: String,
) -> IoResult<RemoteAppServerClient>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (reader, writer) = tokio::io::split(stream);
    RemoteAppServerClient::connect_with_wire(
        args,
        label,
        JsonLineWire {
            reader: BufReader::new(reader),
            writer,
        },
    )
    .await
}
