use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader, ReadHalf, WriteHalf};
use tokio::sync::{Mutex, mpsc, oneshot};

use super::backend::{OpenBackendResult, TerminalBackend, TerminalBackendEvent};
use super::session::{TerminalError, TerminalSize};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
type PendingResponses = Arc<Mutex<HashMap<i64, oneshot::Sender<Result<Value, String>>>>>;

pub(crate) async fn open(
    node_id: String,
    token: String,
    relay: Option<String>,
    shell: Option<String>,
    size: TerminalSize,
) -> Result<OpenBackendResult, TerminalError> {
    let endpoint = crate::ffi::shared::shared_mobile_client()
        .alleycat_endpoint()
        .await
        .map_err(|error| TerminalError::Backend {
            detail: format!("binding alleycat endpoint: {error}"),
        })?;
    let params = crate::alleycat::ParsedPairPayload {
        version: crate::alleycat::ALLEYCAT_PROTOCOL_VERSION,
        node_id,
        token,
        relay,
        host_name: None,
    };
    let (stream, session) =
        crate::alleycat::connect_jsonl_agent_stream(&endpoint, params, "shell".to_string())
            .await
            .map_err(map_shell_connect_error)?;
    let (reader, mut writer) = tokio::io::split(stream);
    let reader = BufReader::new(reader);
    let (output_tx, output_rx) = mpsc::channel(256);
    let pending_responses = Arc::new(Mutex::new(HashMap::new()));
    let shell_session_id = Arc::new(Mutex::new(None));

    tokio::spawn(read_output_loop(
        reader,
        Arc::clone(&shell_session_id),
        output_tx,
        Arc::clone(&pending_responses),
    ));

    let _: Value = tracked_request(
        &mut writer,
        &pending_responses,
        1,
        "initialize",
        json!({
            "clientInfo": { "name": "Litter", "version": "1.0" },
            "capabilities": { "experimentalApi": true }
        }),
    )
    .await?;

    let spawn_response: ShellSpawnResponse = deserialize_result(
        tracked_request(
            &mut writer,
            &pending_responses,
            2,
            "shell/spawn",
            json!({
                "shell": shell,
                "size": { "cols": size.cols, "rows": size.rows }
            }),
        )
        .await?,
        "shell/spawn",
    )?;
    *shell_session_id.lock().await = Some(spawn_response.session_id.clone());

    let backend = Arc::new(RemoteAlleycatBackend {
        writer: Mutex::new(writer),
        session,
        shell_session_id: spawn_response.session_id,
        next_request_id: AtomicI64::new(3),
        pending_responses,
    });
    Ok((backend, output_rx))
}

fn map_shell_connect_error(error: crate::alleycat::AlleycatError) -> TerminalError {
    match error {
        crate::alleycat::AlleycatError::Transport(message)
        | crate::alleycat::AlleycatError::Rejected(message) => {
            if is_shell_agent_unavailable_error(&message) {
                TerminalError::Backend {
                    detail: format!(
                        "Remote shell is unavailable on this Alleycat host. Update and restart kittylitter/alleycat on the host, or enable the host [agents.shell] config. Host said: {message}"
                    ),
                }
            } else {
                TerminalError::Backend {
                    detail: format!("connecting shell bridge: {message}"),
                }
            }
        }
        other => TerminalError::Backend {
            detail: format!("connecting shell bridge: {other}"),
        },
    }
}

fn is_shell_agent_unavailable_error(message: &str) -> bool {
    let normalized = message.to_ascii_lowercase();
    normalized.contains("agent `shell` is disabled or unknown")
        || normalized.contains("agent 'shell' is disabled or unknown")
        || normalized.contains("agent shell is disabled or unknown")
        || normalized.contains("unknown agent `shell`")
        || normalized.contains("unknown agent 'shell'")
        || normalized.contains("unknown agent: shell")
}

async fn tracked_request<W>(
    writer: &mut W,
    pending_responses: &PendingResponses,
    request_id: i64,
    method: &str,
    params: Value,
) -> Result<Value, TerminalError>
where
    W: AsyncWrite + Unpin,
{
    let (tx, rx) = oneshot::channel();
    pending_responses.lock().await.insert(request_id, tx);
    if let Err(error) = send_request(writer, request_id, method, params).await {
        pending_responses.lock().await.remove(&request_id);
        return Err(error);
    }
    await_response(pending_responses, request_id, method, rx).await
}

fn deserialize_result<T>(result: Value, method: &str) -> Result<T, TerminalError>
where
    T: serde::de::DeserializeOwned,
{
    serde_json::from_value(result).map_err(|error| TerminalError::Backend {
        detail: format!("decoding terminal JSON-RPC result for {method}: {error}"),
    })
}

async fn await_response(
    pending_responses: &PendingResponses,
    request_id: i64,
    method: &str,
    rx: oneshot::Receiver<Result<Value, String>>,
) -> Result<Value, TerminalError> {
    match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
        Ok(Ok(Ok(result))) => Ok(result),
        Ok(Ok(Err(message))) => Err(TerminalError::Backend { detail: message }),
        Ok(Err(_)) => Err(TerminalError::Backend {
            detail: "terminal JSON-RPC response channel closed".to_string(),
        }),
        Err(_) => {
            pending_responses.lock().await.remove(&request_id);
            Err(TerminalError::Backend {
                detail: format!("timed out waiting for terminal JSON-RPC response to {method}"),
            })
        }
    }
}

struct RemoteAlleycatBackend {
    writer: Mutex<WriteHalf<crate::alleycat::AlleycatStream>>,
    session: Arc<crate::alleycat::AlleycatSession>,
    shell_session_id: String,
    next_request_id: AtomicI64,
    pending_responses: PendingResponses,
}

#[async_trait]
impl TerminalBackend for RemoteAlleycatBackend {
    async fn write(&self, data: &[u8]) -> Result<(), TerminalError> {
        self.request(
            "shell/input",
            json!({
                "session_id": self.shell_session_id,
                "data_b64": STANDARD.encode(data),
            }),
        )
        .await?;
        Ok(())
    }

    async fn resize(&self, size: TerminalSize) -> Result<(), TerminalError> {
        self.request(
            "shell/resize",
            json!({
                "session_id": self.shell_session_id,
                "cols": size.cols,
                "rows": size.rows,
            }),
        )
        .await?;
        Ok(())
    }

    async fn close(&self) -> Result<(), TerminalError> {
        let result = self
            .request(
                "shell/kill",
                json!({
                    "session_id": self.shell_session_id,
                }),
            )
            .await;
        self.session.close();
        result.map(|_| ())
    }
}

impl RemoteAlleycatBackend {
    fn next_id(&self) -> i64 {
        self.next_request_id.fetch_add(1, Ordering::Relaxed)
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value, TerminalError> {
        let request_id = self.next_id();
        let (tx, rx) = oneshot::channel();
        self.pending_responses.lock().await.insert(request_id, tx);

        let send_result = {
            let mut writer = self.writer.lock().await;
            send_request(&mut *writer, request_id, method, params).await
        };
        if let Err(error) = send_result {
            self.pending_responses.lock().await.remove(&request_id);
            return Err(error);
        }

        await_response(&self.pending_responses, request_id, method, rx).await
    }
}

async fn read_output_loop(
    mut reader: BufReader<ReadHalf<crate::alleycat::AlleycatStream>>,
    shell_session_id: Arc<Mutex<Option<String>>>,
    output_tx: mpsc::Sender<TerminalBackendEvent>,
    pending_responses: PendingResponses,
) {
    let close_reason = loop {
        let mut line = String::new();
        match reader.read_line(&mut line).await {
            Ok(0) => {
                let _ = output_tx.send(TerminalBackendEvent::Exit(-1)).await;
                break "terminal JSON-RPC stream closed".to_string();
            }
            Ok(_) => {}
            Err(error) => {
                let _ = output_tx.send(TerminalBackendEvent::Exit(-1)).await;
                break format!("reading terminal JSON-RPC stream: {error}");
            }
        }
        let Ok(frame) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(id) = frame.get("id").and_then(Value::as_i64) {
            complete_pending_response(&pending_responses, id, response_payload(frame)).await;
            continue;
        }
        match frame.get("method").and_then(Value::as_str) {
            Some("shell/output") => {
                let Some(params) = frame.get("params") else {
                    continue;
                };
                let Ok(params) = serde_json::from_value::<ShellOutputNotification>(params.clone())
                else {
                    continue;
                };
                if !should_accept_session(&shell_session_id, &params.session_id).await {
                    continue;
                }
                let Ok(bytes) = STANDARD.decode(params.data_b64.as_bytes()) else {
                    continue;
                };
                if output_tx
                    .send(TerminalBackendEvent::Bytes(bytes))
                    .await
                    .is_err()
                {
                    break "terminal output listener closed".to_string();
                }
            }
            Some("shell/exit") => {
                let Some(params) = frame.get("params") else {
                    continue;
                };
                let Ok(params) = serde_json::from_value::<ShellExitNotification>(params.clone())
                else {
                    continue;
                };
                if !should_accept_session(&shell_session_id, &params.session_id).await {
                    continue;
                }
                let _ = output_tx
                    .send(TerminalBackendEvent::Exit(params.code))
                    .await;
                break format!("terminal shell session exited with code {}", params.code);
            }
            _ => {}
        }
    };
    fail_pending_responses(&pending_responses, close_reason).await;
}

async fn should_accept_session(
    expected_session_id: &Arc<Mutex<Option<String>>>,
    actual_session_id: &str,
) -> bool {
    match expected_session_id.lock().await.as_deref() {
        Some(expected) => expected == actual_session_id,
        None => true,
    }
}

async fn send_request<W>(
    writer: &mut W,
    id: i64,
    method: &str,
    params: Value,
) -> Result<(), TerminalError>
where
    W: AsyncWrite + Unpin,
{
    let frame = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    });
    let line = serde_json::to_vec(&frame).map_err(|error| TerminalError::Backend {
        detail: format!("encoding terminal JSON-RPC request: {error}"),
    })?;
    writer
        .write_all(&line)
        .await
        .map_err(|error| TerminalError::Backend {
            detail: format!("writing terminal JSON-RPC request: {error}"),
        })?;
    writer
        .write_all(b"\n")
        .await
        .map_err(|error| TerminalError::Backend {
            detail: format!("writing terminal JSON-RPC newline: {error}"),
        })?;
    writer
        .flush()
        .await
        .map_err(|error| TerminalError::Backend {
            detail: format!("flushing terminal JSON-RPC request: {error}"),
        })
}

fn response_payload(frame: Value) -> Result<Value, String> {
    if let Some(error) = frame.get("error") {
        return Err(format!("terminal JSON-RPC error: {error}"));
    }
    frame
        .get("result")
        .cloned()
        .ok_or_else(|| "terminal JSON-RPC response missing result".to_string())
}

async fn complete_pending_response(
    pending_responses: &PendingResponses,
    id: i64,
    payload: Result<Value, String>,
) {
    if let Some(tx) = pending_responses.lock().await.remove(&id) {
        let _ = tx.send(payload);
    }
}

async fn fail_pending_responses(pending_responses: &PendingResponses, detail: String) {
    let pending = {
        let mut pending = pending_responses.lock().await;
        std::mem::take(&mut *pending)
    };
    for (_, tx) in pending {
        let _ = tx.send(Err(detail.clone()));
    }
}

#[derive(Debug, Deserialize)]
struct ShellSpawnResponse {
    session_id: String,
}

#[derive(Debug, Deserialize)]
struct ShellOutputNotification {
    session_id: String,
    data_b64: String,
}

#[derive(Debug, Deserialize)]
struct ShellExitNotification {
    session_id: String,
    code: i32,
}

#[cfg(test)]
mod tests {
    use super::is_shell_agent_unavailable_error;

    #[test]
    fn recognizes_alleycat_shell_agent_unavailable_errors() {
        assert!(is_shell_agent_unavailable_error(
            "agent `shell` is disabled or unknown"
        ));
        assert!(is_shell_agent_unavailable_error("unknown agent: shell"));
        assert!(!is_shell_agent_unavailable_error(
            "agent `codex` is disabled or unknown"
        ));
    }
}
