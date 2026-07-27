use std::collections::{HashMap, VecDeque};
use std::io::{Error as IoError, ErrorKind};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use futures::{Sink, SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc;
use tokio::time::{Instant, MissedTickBehavior};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite;
use tokio_tungstenite::tungstenite::Message;
use tracing::{info, warn};

use crate::api::{SlingshotApi, sanitize_json_bytes, sanitize_json_value};
#[cfg(test)]
use crate::envelope::{EnvelopeType, KnownPongStatus, RemoteControlEnvelope};
use crate::errors::{SlingshotApiError, SlingshotTransportError};
use crate::types::DeviceKeyConnectionChallenge;

const RECONNECT_DELAY: Duration = Duration::from_secs(1);
const WEBSOCKET_PING_INTERVAL: Duration = Duration::from_secs(10);
const WEBSOCKET_PONG_TIMEOUT: Duration = Duration::from_secs(60);
const REMOTE_CONTROL_SEGMENT_TARGET_BYTES: usize = 100 * 1024;
const REMOTE_CONTROL_SEGMENT_MAX_BYTES: usize = 150 * 1024;
const REMOTE_CONTROL_REASSEMBLED_MAX_BYTES: usize = 100 * 1024 * 1024;
const REMOTE_CONTROL_SEGMENT_COUNT_MAX: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlingshotFraming {
    Ndjson,
    Sse,
}

enum OutboundCommand {
    Bytes(Vec<u8>),
    Shutdown,
}

pub struct SlingshotJsonLineStream {
    inbound_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    outbound_tx: mpsc::UnboundedSender<OutboundCommand>,
    read_buf: Vec<u8>,
    shutdown_sent: bool,
    task: tokio::task::JoinHandle<()>,
}

impl SlingshotJsonLineStream {
    pub async fn connect(
        api: SlingshotApi,
        environment_id: String,
        stream_id: String,
    ) -> std::io::Result<Self> {
        let client_id = api.client_id().ok_or_else(|| {
            IoError::new(
                ErrorKind::InvalidInput,
                "slingshot API must be enrolled before connecting",
            )
        })?;
        info!(
            target: "codex_slingshot",
            %client_id,
            %environment_id,
            %stream_id,
            "slingshot json-line stream connecting"
        );
        let (inbound_tx, inbound_rx) = mpsc::unbounded_channel();
        let (outbound_tx, outbound_rx) = mpsc::unbounded_channel();
        let task = tokio::spawn(control_loop(
            api,
            ControlState::new(client_id, environment_id, stream_id),
            inbound_tx,
            outbound_rx,
        ));
        Ok(Self {
            inbound_rx,
            outbound_tx,
            read_buf: Vec::new(),
            shutdown_sent: false,
            task,
        })
    }
}

impl Drop for SlingshotJsonLineStream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl AsyncRead for SlingshotJsonLineStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        loop {
            if !self.read_buf.is_empty() {
                let len = self.read_buf.len().min(buf.remaining());
                buf.put_slice(&self.read_buf[..len]);
                self.read_buf.drain(..len);
                return Poll::Ready(Ok(()));
            }

            match Pin::new(&mut self.inbound_rx).poll_recv(cx) {
                Poll::Ready(Some(bytes)) => {
                    self.read_buf = bytes;
                }
                Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

impl AsyncWrite for SlingshotJsonLineStream {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        self.outbound_tx
            .send(OutboundCommand::Bytes(buf.to_vec()))
            .map_err(|_| IoError::new(ErrorKind::BrokenPipe, "slingshot writer closed"))?;
        Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        if !self.shutdown_sent {
            self.outbound_tx
                .send(OutboundCommand::Shutdown)
                .map_err(|_| IoError::new(ErrorKind::BrokenPipe, "slingshot writer closed"))?;
            self.shutdown_sent = true;
        }
        Poll::Ready(Ok(()))
    }
}

struct ControlState {
    client_id: String,
    environment_id: String,
    stream_id: String,
    next_sequence_id: u64,
    sent_first_client_message: bool,
    wire_replay_queue: VecDeque<ClientWireEnvelope>,
    current_subscribe_cursor: Option<String>,
    latest_inbound_sequence_id: u64,
    chunk_assemblies: HashMap<u64, ChunkAssembly>,
}

impl ControlState {
    fn new(client_id: String, environment_id: String, stream_id: String) -> Self {
        Self {
            client_id,
            environment_id,
            stream_id,
            next_sequence_id: 1,
            sent_first_client_message: false,
            wire_replay_queue: VecDeque::new(),
            current_subscribe_cursor: None,
            latest_inbound_sequence_id: 0,
            chunk_assemblies: HashMap::new(),
        }
    }

    fn allocate_sequence_id(&mut self) -> u64 {
        let sequence_id = self.next_sequence_id;
        self.next_sequence_id = self.next_sequence_id.saturating_add(1);
        sequence_id
    }

    fn client_message_wire_envelopes(
        &mut self,
        message: serde_json::Value,
    ) -> Result<Vec<ClientWireEnvelope>, SlingshotApiError> {
        self.sent_first_client_message = true;
        let seq_id = self.allocate_sequence_id();
        let envelope = ClientWireEnvelope {
            event: ClientWireEvent::ClientMessage { message },
            client_id: self.client_id.clone(),
            env_id: Some(self.environment_id.clone()),
            stream_id: Some(self.stream_id.clone()),
            seq_id: Some(seq_id),
            cursor: self.current_subscribe_cursor.clone(),
        };
        split_client_wire_envelope_for_transport(envelope)
    }

    fn client_closed_wire(&mut self) -> ClientWireEnvelope {
        ClientWireEnvelope {
            event: ClientWireEvent::ClientClosed,
            client_id: self.client_id.clone(),
            env_id: Some(self.environment_id.clone()),
            stream_id: Some(self.stream_id.clone()),
            seq_id: Some(self.allocate_sequence_id()),
            cursor: self.current_subscribe_cursor.clone(),
        }
    }

}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientWireEvent {
    ClientMessage {
        message: serde_json::Value,
    },
    ClientMessageChunk {
        segment_id: usize,
        segment_count: usize,
        message_size_bytes: usize,
        message_chunk_base64: String,
    },
    ClientClosed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
struct ClientWireEnvelope {
    #[serde(flatten)]
    event: ClientWireEvent,
    client_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    env_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stream_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    seq_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cursor: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerWireEvent {
    ServerMessage {
        message: serde_json::Value,
    },
    ServerMessageChunk {
        segment_id: usize,
        segment_count: usize,
        message_size_bytes: usize,
        message_chunk_base64: String,
    },
    Ack,
    Pong {
        status: Option<String>,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
struct ServerWireEnvelope {
    #[serde(flatten)]
    event: ServerWireEvent,
    client_id: String,
    env_id: Option<String>,
    stream_id: Option<String>,
    seq_id: Option<u64>,
    cursor: Option<String>,
}

#[derive(Debug)]
struct ChunkAssembly {
    segment_count: usize,
    message_size_bytes: usize,
    chunks: Vec<Option<Vec<u8>>>,
}

fn split_client_wire_envelope_for_transport(
    envelope: ClientWireEnvelope,
) -> Result<Vec<ClientWireEnvelope>, SlingshotApiError> {
    if !matches!(envelope.event, ClientWireEvent::ClientMessage { .. }) {
        return Ok(vec![envelope]);
    }

    let envelope_size = serde_json::to_vec(&envelope)?.len();
    if envelope_size <= REMOTE_CONTROL_SEGMENT_MAX_BYTES {
        return Ok(vec![envelope]);
    }

    let ClientWireEvent::ClientMessage { message } = &envelope.event else {
        unreachable!("client message variant checked above");
    };
    let raw = serde_json::to_vec(message)?;
    let message_size_bytes = raw.len();
    if message_size_bytes > REMOTE_CONTROL_REASSEMBLED_MAX_BYTES {
        return Err(SlingshotApiError::WebSocket(format!(
            "remote-control client message exceeds reassembled size limit ({message_size_bytes} bytes)"
        )));
    }

    let segment_count = usize::max(
        2,
        message_size_bytes.div_ceil(REMOTE_CONTROL_SEGMENT_TARGET_BYTES),
    );
    if segment_count > REMOTE_CONTROL_SEGMENT_COUNT_MAX {
        return Err(SlingshotApiError::WebSocket(format!(
            "remote-control client message requires too many segments ({segment_count})"
        )));
    }
    let chunk_size = usize::max(1, message_size_bytes.div_ceil(segment_count));
    let mut segments = Vec::with_capacity(segment_count);
    for (segment_id, chunk) in raw.chunks(chunk_size).enumerate() {
        let segment = ClientWireEnvelope {
            event: ClientWireEvent::ClientMessageChunk {
                segment_id,
                segment_count,
                message_size_bytes,
                message_chunk_base64: STANDARD.encode(chunk),
            },
            client_id: envelope.client_id.clone(),
            env_id: envelope.env_id.clone(),
            stream_id: envelope.stream_id.clone(),
            seq_id: envelope.seq_id,
            cursor: envelope.cursor.clone(),
        };
        let segment_size = serde_json::to_vec(&segment)?.len();
        if segment_size > REMOTE_CONTROL_SEGMENT_MAX_BYTES {
            return Err(SlingshotApiError::WebSocket(format!(
                "remote-control client segment exceeds wire size limit ({segment_size} bytes)"
            )));
        }
        segments.push(segment);
    }
    Ok(segments)
}

async fn control_loop(
    api: SlingshotApi,
    mut state: ControlState,
    inbound_tx: mpsc::UnboundedSender<Vec<u8>>,
    mut outbound_rx: mpsc::UnboundedReceiver<OutboundCommand>,
) {
    let mut outbound_line_buf = Vec::new();
    loop {
        let request = match api.websocket_request(state.current_subscribe_cursor.as_deref()) {
            Ok(request) => request,
            Err(error) => {
                warn!(
                    target: "codex_slingshot",
                    %error,
                    client_id = %state.client_id,
                    environment_id = %state.environment_id,
                    stream_id = %state.stream_id,
                    cursor = ?state.current_subscribe_cursor,
                    "slingshot websocket request failed"
                );
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };
        info!(
            target: "codex_slingshot",
            client_id = %state.client_id,
            environment_id = %state.environment_id,
            stream_id = %state.stream_id,
            cursor = ?state.current_subscribe_cursor,
            replay_count = state.wire_replay_queue.len(),
            "slingshot websocket connecting"
        );
        let (websocket, response) = match connect_async(request).await {
            Ok(connected) => connected,
            Err(error) => {
                warn!(
                    target: "codex_slingshot",
                    %error,
                    client_id = %state.client_id,
                    environment_id = %state.environment_id,
                    stream_id = %state.stream_id,
                    "slingshot websocket connect failed"
                );
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };
        info!(
            target: "codex_slingshot",
            status = %response.status(),
            client_id = %state.client_id,
            environment_id = %state.environment_id,
            stream_id = %state.stream_id,
            "slingshot websocket connected"
        );
        let (mut ws_tx, mut ws_rx) = websocket.split();
        if api.requires_device_key_handshake() {
            if let Err(error) = complete_device_key_handshake(&api, &mut ws_tx, &mut ws_rx).await {
                warn!(
                    target: "codex_slingshot",
                    %error,
                    client_id = %state.client_id,
                    environment_id = %state.environment_id,
                    stream_id = %state.stream_id,
                    "slingshot websocket device-key handshake failed"
                );
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        }
        if let Err(error) = replay_unacked_wire(&mut ws_tx, &state).await {
            warn!(
                target: "codex_slingshot",
                %error,
                replay_count = state.wire_replay_queue.len(),
                "slingshot replay failed after websocket connect"
            );
            tokio::time::sleep(RECONNECT_DELAY).await;
            continue;
        }

        let mut ping_interval = tokio::time::interval_at(
            Instant::now() + WEBSOCKET_PING_INTERVAL,
            WEBSOCKET_PING_INTERVAL,
        );
        ping_interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let pong_deadline = tokio::time::sleep(WEBSOCKET_PONG_TIMEOUT);
        tokio::pin!(pong_deadline);

        loop {
            tokio::select! {
                _ = ping_interval.tick() => {
                    if let Err(error) = ws_tx.send(Message::Ping(Vec::new().into())).await {
                        warn!(target: "codex_slingshot", %error, "slingshot websocket ping failed");
                        break;
                    }
                }
                _ = &mut pong_deadline => {
                    warn!(
                        target: "codex_slingshot",
                        timeout_secs = WEBSOCKET_PONG_TIMEOUT.as_secs(),
                        "slingshot websocket pong timeout"
                    );
                    break;
                }
                command = outbound_rx.recv() => {
                    match command {
                        Some(OutboundCommand::Bytes(bytes)) => {
                            if let Err(error) = handle_outbound_bytes_wire(
                                &mut ws_tx,
                                &mut state,
                                &mut outbound_line_buf,
                                &bytes,
                            )
                            .await {
                                warn!(target: "codex_slingshot", %error, "slingshot outbound failed");
                                break;
                            }
                        }
                        Some(OutboundCommand::Shutdown) => {
                            let envelope = state.client_closed_wire();
                            if let Err(error) = send_wire_envelope(&mut ws_tx, &envelope).await {
                                warn!(target: "codex_slingshot", %error, "slingshot client close failed");
                            }
                            return;
                        }
                        None => return,
                    }
                }
                message = ws_rx.next() => {
                    match message {
                        Some(Ok(message)) => {
                            let observed_pong = matches!(message, Message::Pong(_));
                            if let Err(error) = handle_websocket_message(
                                &api,
                                &mut ws_tx,
                                &mut state,
                                &inbound_tx,
                                message,
                            )
                            .await {
                                warn!(target: "codex_slingshot", %error, "slingshot websocket inbound failed");
                                break;
                            }
                            if observed_pong {
                                pong_deadline
                                    .as_mut()
                                    .reset(Instant::now() + WEBSOCKET_PONG_TIMEOUT);
                            }
                        }
                        Some(Err(error)) => {
                            warn!(target: "codex_slingshot", %error, "slingshot websocket stream failed");
                            break;
                        }
                        None => {
                            info!(target: "codex_slingshot", "slingshot websocket stream ended");
                            break;
                        }
                    }
                }
            }
        }

        tokio::time::sleep(RECONNECT_DELAY).await;
    }
}

async fn send_wire_envelope<S>(
    sink: &mut S,
    envelope: &ClientWireEnvelope,
) -> Result<(), SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
{
    let encoded = serde_json::to_string(envelope)?;
    info!(
        target: "codex_slingshot",
        direction = "outbound",
        event = %client_wire_event_name(envelope),
        client_id = %envelope.client_id,
        env_id = ?envelope.env_id,
        stream_id = ?envelope.stream_id,
        seq_id = ?envelope.seq_id,
        cursor = ?envelope.cursor,
        payload = %sanitize_json_value(&serde_json::to_value(envelope)?),
        "slingshot websocket message"
    );
    sink.send(Message::Text(encoded.into()))
        .await
        .map_err(|error| SlingshotApiError::WebSocket(error.to_string()))
}

async fn replay_unacked_wire<S>(sink: &mut S, state: &ControlState) -> Result<(), SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
{
    info!(
        target: "codex_slingshot",
        replay_count = state.wire_replay_queue.len(),
        "slingshot websocket replaying unacked messages"
    );
    for envelope in &state.wire_replay_queue {
        send_wire_envelope(sink, envelope).await?;
    }
    Ok(())
}

async fn complete_device_key_handshake<S, R>(
    api: &SlingshotApi,
    sink: &mut S,
    stream: &mut R,
) -> Result<(), SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
    R: futures::Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
{
    info!(
        target: "codex_slingshot",
        "slingshot websocket waiting for device-key challenge"
    );
    loop {
        let message = stream
            .next()
            .await
            .ok_or_else(|| {
                SlingshotApiError::WebSocket(
                    "remote control websocket ended before device-key challenge".to_string(),
                )
            })?
            .map_err(|error| SlingshotApiError::WebSocket(error.to_string()))?;
        match message {
            Message::Text(text) => {
                info!(
                    target: "codex_slingshot",
                    direction = "inbound",
                    frame = "text",
                    bytes = text.len(),
                    payload = %sanitize_json_bytes(text.as_bytes()),
                    "slingshot websocket raw message"
                );
                if try_handle_device_key_challenge(api, sink, text.as_bytes()).await? {
                    info!(
                        target: "codex_slingshot",
                        "slingshot websocket device-key proof sent"
                    );
                    return Ok(());
                }
                return Err(SlingshotApiError::WebSocket(
                    "expected device-key challenge before application messages".to_string(),
                ));
            }
            Message::Binary(bytes) => {
                info!(
                    target: "codex_slingshot",
                    direction = "inbound",
                    frame = "binary",
                    bytes = bytes.len(),
                    payload = %sanitize_json_bytes(&bytes),
                    "slingshot websocket raw message"
                );
                if try_handle_device_key_challenge(api, sink, &bytes).await? {
                    info!(
                        target: "codex_slingshot",
                        "slingshot websocket device-key proof sent"
                    );
                    return Ok(());
                }
                return Err(SlingshotApiError::WebSocket(
                    "expected device-key challenge before application messages".to_string(),
                ));
            }
            Message::Ping(bytes) => {
                info!(
                    target: "codex_slingshot",
                    bytes = bytes.len(),
                    "slingshot websocket ping received during device-key handshake"
                );
                sink.send(Message::Pong(bytes))
                    .await
                    .map_err(|error| SlingshotApiError::WebSocket(error.to_string()))?;
            }
            Message::Pong(bytes) => {
                info!(
                    target: "codex_slingshot",
                    bytes = bytes.len(),
                    "slingshot websocket pong received during device-key handshake"
                );
            }
            Message::Close(frame) => {
                warn!(
                    target: "codex_slingshot",
                    close = ?frame,
                    "slingshot websocket close received during device-key handshake"
                );
                return Err(SlingshotApiError::WebSocket(
                    "remote control websocket closed during device-key handshake".to_string(),
                ));
            }
            Message::Frame(_) => {}
        }
    }
}

async fn try_handle_device_key_challenge<S>(
    api: &SlingshotApi,
    sink: &mut S,
    payload: &[u8],
) -> Result<bool, SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
{
    let value: serde_json::Value = serde_json::from_slice(payload)?;
    if !value
        .get("type")
        .and_then(|value| value.as_str())
        .is_some_and(|kind| kind == "device_key_challenge")
    {
        return Ok(false);
    }

    let challenge: DeviceKeyConnectionChallenge = serde_json::from_value(value)?;
    info!(
        target: "codex_slingshot",
        client_id = %challenge.client_id,
        account_user_id = %challenge.account_user_id,
        session_id = %challenge.session_id,
        target_origin = %challenge.target_origin,
        target_path = %challenge.target_path,
        scopes = ?challenge.scopes,
        "slingshot websocket device-key challenge decoded"
    );
    let device_key = api
        .device_key()
        .ok_or(SlingshotApiError::MissingDeviceKey)?;
    let proof = device_key.sign_connection_challenge(&challenge)?;
    info!(
        target: "codex_slingshot",
        key_id = %proof.key_id,
        algorithm = %proof.algorithm,
        payload = %sanitize_json_value(&serde_json::to_value(&proof)?),
        "slingshot websocket device-key proof sending"
    );
    sink.send(Message::Text(serde_json::to_string(&proof)?.into()))
        .await
        .map_err(|error| SlingshotApiError::WebSocket(error.to_string()))?;
    Ok(true)
}

async fn handle_outbound_bytes_wire<S>(
    sink: &mut S,
    state: &mut ControlState,
    outbound_line_buf: &mut Vec<u8>,
    bytes: &[u8],
) -> Result<(), SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
{
    outbound_line_buf.extend_from_slice(bytes);
    while let Some(line) = drain_line(outbound_line_buf) {
        let trimmed = trim_ascii_whitespace(&line);
        if trimmed.is_empty() {
            continue;
        }
        let message: serde_json::Value = serde_json::from_slice(trimmed)?;
        if !message.is_object() {
            return Err(SlingshotTransportError::InvalidClientPayload.into());
        }
        info!(
            target: "codex_slingshot",
            direction = "outbound",
            payload = %sanitize_json_value(&message),
            "slingshot json-rpc outbound frame"
        );
        let envelopes = state.client_message_wire_envelopes(message)?;
        for envelope in envelopes {
            state.wire_replay_queue.push_back(envelope.clone());
            send_wire_envelope(sink, &envelope).await?;
        }
    }
    Ok(())
}

async fn handle_websocket_message<S>(
    api: &SlingshotApi,
    sink: &mut S,
    state: &mut ControlState,
    inbound_tx: &mpsc::UnboundedSender<Vec<u8>>,
    message: Message,
) -> Result<(), SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
{
    match message {
        Message::Text(text) => {
            info!(
                target: "codex_slingshot",
                direction = "inbound",
                frame = "text",
                bytes = text.len(),
                payload = %sanitize_json_bytes(text.as_bytes()),
                "slingshot websocket raw message"
            );
            handle_websocket_payload(api, sink, state, inbound_tx, text.as_bytes()).await
        }
        Message::Binary(bytes) => {
            info!(
                target: "codex_slingshot",
                direction = "inbound",
                frame = "binary",
                bytes = bytes.len(),
                payload = %sanitize_json_bytes(&bytes),
                "slingshot websocket raw message"
            );
            handle_websocket_payload(api, sink, state, inbound_tx, &bytes).await
        }
        Message::Ping(bytes) => {
            info!(
                target: "codex_slingshot",
                bytes = bytes.len(),
                "slingshot websocket ping received"
            );
            sink.send(Message::Pong(bytes))
                .await
                .map_err(|error| SlingshotApiError::WebSocket(error.to_string()))
        }
        Message::Pong(bytes) => {
            info!(
                target: "codex_slingshot",
                bytes = bytes.len(),
                "slingshot websocket pong received"
            );
            Ok(())
        }
        Message::Close(frame) => {
            warn!(
                target: "codex_slingshot",
                close = ?frame,
                "slingshot websocket close received"
            );
            Err(SlingshotApiError::WebSocket(
                "remote control websocket closed".to_string(),
            ))
        }
        Message::Frame(_) => Ok(()),
    }
}

async fn handle_websocket_payload<S>(
    api: &SlingshotApi,
    sink: &mut S,
    state: &mut ControlState,
    inbound_tx: &mpsc::UnboundedSender<Vec<u8>>,
    payload: &[u8],
) -> Result<(), SlingshotApiError>
where
    S: Sink<Message, Error = tungstenite::Error> + Unpin,
{
    if try_handle_device_key_challenge(api, sink, payload).await? {
        return Ok(());
    }

    let value: serde_json::Value = serde_json::from_slice(payload)?;
    let envelope: ServerWireEnvelope = serde_json::from_value(value)?;
    info!(
        target: "codex_slingshot",
        direction = "inbound",
        event = %server_wire_event_name(&envelope),
        client_id = %envelope.client_id,
        env_id = ?envelope.env_id,
        stream_id = ?envelope.stream_id,
        seq_id = ?envelope.seq_id,
        cursor = ?envelope.cursor,
        "slingshot websocket envelope decoded"
    );
    handle_inbound_wire_envelope(state, inbound_tx, envelope).await
}

async fn handle_inbound_wire_envelope(
    state: &mut ControlState,
    inbound_tx: &mpsc::UnboundedSender<Vec<u8>>,
    envelope: ServerWireEnvelope,
) -> Result<(), SlingshotApiError> {
    if let Some(cursor) = envelope.cursor.clone() {
        state.current_subscribe_cursor = Some(cursor);
    }
    if let Some(seq_id) = envelope.seq_id {
        state.latest_inbound_sequence_id = seq_id;
    }
    match &envelope.event {
        ServerWireEvent::ServerMessage { message } => {
            info!(
                target: "codex_slingshot",
                seq_id = ?envelope.seq_id,
                payload = %sanitize_json_value(message),
                "slingshot server message delivering"
            );
            deliver_jsonrpc_message(inbound_tx, message.clone())?;
        }
        ServerWireEvent::ServerMessageChunk {
            segment_id,
            segment_count,
            message_size_bytes,
            message_chunk_base64,
        } => {
            let seq_id = envelope
                .seq_id
                .ok_or(SlingshotTransportError::MissingSequenceId)?;
            observe_server_message_chunk(
                state,
                inbound_tx,
                seq_id,
                *segment_id,
                *segment_count,
                *message_size_bytes,
                message_chunk_base64,
            )?;
            info!(
                target: "codex_slingshot",
                seq_id,
                segment_id,
                segment_count,
                message_size_bytes,
                "slingshot server message chunk observed"
            );
        }
        ServerWireEvent::Ack => {
            if let Some(acked) = envelope.seq_id {
                let before = state.wire_replay_queue.len();
                state
                    .wire_replay_queue
                    .retain(|queued| queued.seq_id.is_none_or(|seq_id| seq_id > acked));
                info!(
                    target: "codex_slingshot",
                    acked_seq_id = acked,
                    replay_before = before,
                    replay_after = state.wire_replay_queue.len(),
                    "slingshot ack trimmed replay queue"
                );
            }
        }
        ServerWireEvent::Pong { status } => {
            info!(
                target: "codex_slingshot",
                status = ?status,
                "slingshot application pong received"
            );
        }
    }
    Ok(())
}

fn client_wire_event_name(envelope: &ClientWireEnvelope) -> &'static str {
    match &envelope.event {
        ClientWireEvent::ClientMessage { .. } => "client_message",
        ClientWireEvent::ClientMessageChunk { .. } => "client_message_chunk",
        ClientWireEvent::ClientClosed => "client_closed",
    }
}

fn server_wire_event_name(envelope: &ServerWireEnvelope) -> &'static str {
    match &envelope.event {
        ServerWireEvent::ServerMessage { .. } => "server_message",
        ServerWireEvent::ServerMessageChunk { .. } => "server_message_chunk",
        ServerWireEvent::Ack => "ack",
        ServerWireEvent::Pong { .. } => "pong",
    }
}

fn observe_server_message_chunk(
    state: &mut ControlState,
    inbound_tx: &mpsc::UnboundedSender<Vec<u8>>,
    seq_id: u64,
    segment_id: usize,
    segment_count: usize,
    message_size_bytes: usize,
    message_chunk_base64: &str,
) -> Result<(), SlingshotApiError> {
    if segment_count == 0 || segment_id >= segment_count {
        return Err(
            SlingshotTransportError::InvalidServerPayload(serde_json::json!({
                "seq_id": seq_id,
                "segment_id": segment_id,
                "segment_count": segment_count,
            }))
            .into(),
        );
    }
    let chunk = STANDARD
        .decode(message_chunk_base64)
        .map_err(|error| SlingshotApiError::WebSocket(error.to_string()))?;
    let assembly = state
        .chunk_assemblies
        .entry(seq_id)
        .or_insert_with(|| ChunkAssembly {
            segment_count,
            message_size_bytes,
            chunks: vec![None; segment_count],
        });
    if assembly.segment_count != segment_count
        || assembly.message_size_bytes != message_size_bytes
        || assembly.chunks.len() != segment_count
    {
        state.chunk_assemblies.remove(&seq_id);
        return Err(
            SlingshotTransportError::InvalidServerPayload(serde_json::json!({
                "seq_id": seq_id,
                "segment_id": segment_id,
                "segment_count": segment_count,
            }))
            .into(),
        );
    }
    assembly.chunks[segment_id] = Some(chunk);
    if assembly.chunks.iter().all(Option::is_some) {
        let assembly = state
            .chunk_assemblies
            .remove(&seq_id)
            .expect("assembly exists");
        let mut bytes = Vec::with_capacity(assembly.message_size_bytes);
        for chunk in assembly.chunks.into_iter().flatten() {
            bytes.extend_from_slice(&chunk);
        }
        if bytes.len() != assembly.message_size_bytes {
            return Err(
                SlingshotTransportError::InvalidServerPayload(serde_json::json!({
                    "seq_id": seq_id,
                    "message_size_bytes": assembly.message_size_bytes,
                    "actual_size_bytes": bytes.len(),
                }))
                .into(),
            );
        }
        let message: serde_json::Value = serde_json::from_slice(&bytes)?;
        deliver_jsonrpc_message(inbound_tx, message)?;
    }
    Ok(())
}

fn deliver_jsonrpc_message(
    inbound_tx: &mpsc::UnboundedSender<Vec<u8>>,
    message: serde_json::Value,
) -> Result<(), SlingshotApiError> {
    let mut line = serde_json::to_vec(&message)?;
    line.push(b'\n');
    inbound_tx
        .send(line)
        .map_err(|_| IoError::new(ErrorKind::BrokenPipe, "slingshot reader closed"))?;
    Ok(())
}

#[cfg(test)]
fn pull_envelopes(
    buf: &mut Vec<u8>,
    framing: SlingshotFraming,
) -> Result<Vec<RemoteControlEnvelope>, SlingshotApiError> {
    match framing {
        SlingshotFraming::Ndjson => pull_ndjson_envelopes(buf),
        SlingshotFraming::Sse => pull_sse_envelopes(buf),
    }
}

#[cfg(test)]
fn pull_ndjson_envelopes(
    buf: &mut Vec<u8>,
) -> Result<Vec<RemoteControlEnvelope>, SlingshotApiError> {
    let mut envelopes = Vec::new();
    while let Some(line) = drain_line(buf) {
        let trimmed = trim_ascii_whitespace(&line);
        if trimmed.is_empty() {
            continue;
        }
        envelopes.push(serde_json::from_slice(trimmed)?);
    }
    Ok(envelopes)
}

#[cfg(test)]
fn pull_sse_envelopes(buf: &mut Vec<u8>) -> Result<Vec<RemoteControlEnvelope>, SlingshotApiError> {
    let mut envelopes = Vec::new();
    while let Some(event) = drain_sse_event(buf) {
        let mut data_lines = Vec::new();
        for raw_line in event.split(|byte| *byte == b'\n') {
            let line = raw_line.strip_suffix(b"\r").unwrap_or(raw_line);
            let Some(rest) = line.strip_prefix(b"data:") else {
                continue;
            };
            let rest = rest.strip_prefix(b" ").unwrap_or(rest);
            data_lines.extend_from_slice(rest);
            data_lines.push(b'\n');
        }
        let trimmed = trim_ascii_whitespace(&data_lines);
        if trimmed.is_empty() || trimmed == b"[DONE]" {
            continue;
        }
        envelopes.push(serde_json::from_slice(trimmed)?);
    }
    Ok(envelopes)
}

fn drain_line(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    let pos = buf.iter().position(|byte| *byte == b'\n')?;
    let mut line = buf.drain(..=pos).collect::<Vec<_>>();
    if line.last() == Some(&b'\n') {
        line.pop();
    }
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    Some(line)
}

#[cfg(test)]
fn drain_sse_event(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    if let Some(pos) = find_subslice(buf, b"\n\n") {
        return Some(buf.drain(..pos + 2).collect());
    }
    if let Some(pos) = find_subslice(buf, b"\r\n\r\n") {
        return Some(buf.drain(..pos + 4).collect());
    }
    None
}

#[cfg(test)]
fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn trim_ascii_whitespace(bytes: &[u8]) -> &[u8] {
    let mut start = 0;
    let mut end = bytes.len();
    while start < end && bytes[start].is_ascii_whitespace() {
        start += 1;
    }
    while end > start && bytes[end - 1].is_ascii_whitespace() {
        end -= 1;
    }
    &bytes[start..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn client_wire_message_includes_environment_id() {
        let mut state = ControlState::new(
            "cli_1".to_string(),
            "env_1".to_string(),
            "stream_1".to_string(),
        );

        let envelopes = state
            .client_message_wire_envelopes(json!({
            "id": "initialize",
            "method": "initialize",
            }))
            .unwrap();

        assert_eq!(envelopes.len(), 1);
        assert_eq!(
            serde_json::to_value(&envelopes[0]).unwrap(),
            json!({
                "type": "client_message",
                "client_id": "cli_1",
                "env_id": "env_1",
                "stream_id": "stream_1",
                "seq_id": 1,
                "message": {
                    "id": "initialize",
                    "method": "initialize",
                },
            })
        );
    }

    #[test]
    fn client_wire_message_chunks_large_payloads() {
        let mut state = ControlState::new(
            "cli_1".to_string(),
            "env_1".to_string(),
            "stream_1".to_string(),
        );

        let envelopes = state
            .client_message_wire_envelopes(json!({
                "id": "large",
                "method": "submitInput",
                "params": {
                    "text": "x".repeat(180 * 1024),
                },
            }))
            .unwrap();

        assert!(envelopes.len() > 1);
        for (segment_id, envelope) in envelopes.iter().enumerate() {
            let encoded = serde_json::to_vec(envelope).unwrap();
            assert!(encoded.len() <= REMOTE_CONTROL_SEGMENT_MAX_BYTES);
            assert_eq!(envelope.client_id, "cli_1");
            assert_eq!(envelope.env_id.as_deref(), Some("env_1"));
            assert_eq!(envelope.stream_id.as_deref(), Some("stream_1"));
            assert_eq!(envelope.seq_id, Some(1));

            match &envelope.event {
                ClientWireEvent::ClientMessageChunk {
                    segment_id: actual_segment_id,
                    segment_count,
                    message_size_bytes,
                    message_chunk_base64,
                } => {
                    assert_eq!(*actual_segment_id, segment_id);
                    assert_eq!(*segment_count, envelopes.len());
                    assert!(*message_size_bytes > REMOTE_CONTROL_SEGMENT_MAX_BYTES);
                    assert!(!message_chunk_base64.is_empty());
                }
                other => panic!("expected client message chunk, got {other:?}"),
            }
        }
    }

    #[test]
    fn parses_ndjson_envelopes() {
        let mut buf = br#"{"type":"ping","clientId":"C","sequenceId":1}
{"type":"pong","clientId":"C","sequenceId":2,"status":"active"}
"#
        .to_vec();
        let envelopes = pull_envelopes(&mut buf, SlingshotFraming::Ndjson).unwrap();
        assert_eq!(envelopes.len(), 2);
        assert_eq!(envelopes[0].kind, EnvelopeType::Ping);
        assert_eq!(envelopes[1].status, Some(KnownPongStatus::Active));
        assert!(buf.is_empty());
    }

    #[test]
    fn parses_sse_data_envelopes() {
        let mut buf = br#"event: message
data: {"type":"ping","clientId":"C","sequenceId":1}

"#
        .to_vec();
        let envelopes = pull_envelopes(&mut buf, SlingshotFraming::Sse).unwrap();
        assert_eq!(envelopes.len(), 1);
        assert_eq!(envelopes[0].kind, EnvelopeType::Ping);
    }
}
