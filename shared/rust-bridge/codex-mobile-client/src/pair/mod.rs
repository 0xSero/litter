//! iPhone ↔ Mac proximity pairing protocol.
//!
//! On the unsandboxed (direct-dist) Mac the app advertises a Bonjour
//! service `_litter-pair._tcp.` whose port hosts a tiny WebSocket server.
//! The iPhone discovers it, opens a WebSocket, and the two sides exchange
//! NearbyInteraction (NI) discovery tokens. When the iPhone reports it is
//! physically close, the Mac shows a native confirm dialog; on accept, it
//! returns its LAN IP and the iPhone saves a `SavedServer` pointing at the
//! Feature A local codex.
//!
//! This module owns:
//!   * the JSON-over-WS protocol message shapes
//!   * the per-side state machine (`PairHostSession`, `PairClientSession`)
//!   * a small queue of `PairEvent`s the platform polls (Swift cannot
//!     consume async streams over the UniFFI boundary cleanly, so we expose
//!     a poll-style interface — same shape as the broader `AppStore`
//!     subscription model uses for Swift)
//!
//! Bonjour publish/browse and the actual `NISession` live on the Swift
//! side; this module never parses NSNetService / Apple framework wire
//! formats, only opaque tokens passed through as base64 strings.
//!
//! Distance reporting note: no current Mac ships with U1/U2, so the Mac
//! side falls back to BLE ranging at ~1–2m precision. Use a 1.0m
//! threshold for the "close enough to confirm" trigger.

use std::collections::VecDeque;
use std::sync::Arc;

use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{accept_async, connect_async};
use tracing::{debug, info, warn};

// ── Wire protocol ────────────────────────────────────────────────────────

/// Top-level pair protocol envelope. Every message carries a `type` tag so
/// either side can route on it without parsing wire-format strings on the
/// platform.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum PairWireMessage {
    Hello {
        device_name: String,
        ni_discovery_token_b64: String,
    },
    HelloAck {
        ni_discovery_token_b64: String,
    },
    PairRequest {
        distance_m: Option<f32>,
    },
    PairAccept {
        codex_ws_url: String,
        lan_ip: String,
    },
    PairReject {
        reason: Option<String>,
    },
    /// Periodic distance ping from the iPhone. Optional — used only for UI
    /// affordances on the Mac (e.g., "iPhone 1.4m away" before the user
    /// asks to pair). Carries no decision.
    DistanceUpdate {
        distance_m: f32,
    },
}

// ── UniFFI surface ───────────────────────────────────────────────────────

/// Service info returned by `start_pair_host`. Swift uses these fields to
/// publish a NetService (`_litter-pair._tcp.`) on the Mac side.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PairServiceInfo {
    /// Suggested Bonjour service instance name. Swift may override.
    pub service_name: String,
    /// TCP port the WS server is bound to. Always non-zero.
    pub port: u16,
    /// TXT record entries in `key=value` form. Swift converts to a TXT
    /// dictionary before publishing.
    pub txt_entries: Vec<String>,
}

/// Polled events surfaced to Swift on either side. `None` means "no events
/// pending — call again later". Identical poll semantics on host + client
/// keeps Swift glue uniform.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum PairEvent {
    /// Host side — an iPhone connected and sent its hello. Swift can use
    /// this to start NI on the Mac with the iPhone's discovery token.
    HostPeerConnected {
        device_name: String,
        ni_discovery_token_b64: String,
    },
    /// Client side — Mac responded with its NI discovery token. Swift can
    /// start NI on the iPhone with the Mac's discovery token.
    ClientPeerAccepted { ni_discovery_token_b64: String },
    /// Host side — iPhone says it's close enough to pair. Swift should show
    /// the confirm dialog and call `accept_pair_request`.
    HostPairRequest { distance_m: Option<f32> },
    /// Client side — Mac accepted the pair request. Save the server.
    ClientPairAccepted {
        codex_ws_url: String,
        lan_ip: String,
    },
    /// Either side — the peer disconnected or rejected. `reason` is a short
    /// human-readable hint when present.
    PeerRejected { reason: Option<String> },
    /// Either side — the underlying WebSocket failed; the session is dead.
    Disconnected { reason: String },
    /// Host side — periodic distance ping from the iPhone. Useful for "X
    /// meters away" affordances before the formal request. No action
    /// needed.
    DistanceUpdate { distance_m: f32 },
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PairError {
    #[error("transport: {0}")]
    Transport(String),
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("invalid state: {0}")]
    InvalidState(String),
}

// ── Shared event queue ───────────────────────────────────────────────────

/// FIFO queue of events surfaced to Swift via `poll_event`. Swift polls on
/// a timer (typically 100ms) — when there's nothing pending we return
/// `None` cheaply. We never block on this side.
#[derive(Default)]
struct EventQueue {
    inner: tokio::sync::Mutex<VecDeque<PairEvent>>,
}

impl EventQueue {
    async fn push(&self, event: PairEvent) {
        let mut guard = self.inner.lock().await;
        guard.push_back(event);
    }

    async fn pop(&self) -> Option<PairEvent> {
        let mut guard = self.inner.lock().await;
        guard.pop_front()
    }
}

// ── Wire helpers ─────────────────────────────────────────────────────────

async fn send_wire<S>(ws: &mut S, msg: &PairWireMessage) -> Result<(), PairError>
where
    S: futures::Sink<WsMessage, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    let json = serde_json::to_string(msg)
        .map_err(|err| PairError::Protocol(format!("serialize: {err}")))?;
    ws.send(WsMessage::Text(json.into()))
        .await
        .map_err(|err| PairError::Transport(err.to_string()))
}

fn parse_wire(text: &str) -> Result<PairWireMessage, PairError> {
    serde_json::from_str(text).map_err(|err| PairError::Protocol(format!("parse: {err}")))
}

// ── Host side (Mac) ──────────────────────────────────────────────────────

/// Per-iPhone session held on the Mac. Drops the WS task and stops the
/// listener when this goes away.
#[derive(uniffi::Object)]
pub struct PairHostHandle {
    listener_task: Mutex<Option<JoinHandle<()>>>,
    /// Currently-paired iPhone's outbound channel. We only support one
    /// in-flight pair attempt at a time on the host; new connections drop
    /// the previous in-flight attempt. Pair-after-accept Bonjour stays up
    /// for repeat pairings.
    active: Arc<Mutex<Option<HostActiveSession>>>,
    events: Arc<EventQueue>,
    port: u16,
}

struct HostActiveSession {
    /// Sender into the WS pipeline. The reader/writer pair is split so the
    /// dedicated reader task drives event push while user actions on the
    /// Mac UI route through `out_tx`.
    out_tx: tokio::sync::mpsc::UnboundedSender<PairWireMessage>,
    /// NI discovery token to hand back on the next hello_ack. May be
    /// updated by `host_set_ni_discovery_token`.
    pending_ni_token_b64: Option<String>,
    /// Already-handshook hello? Once true, we've sent hello_ack and the
    /// Mac can call `accept_pair_request`.
    handshook: bool,
}

#[uniffi::export(async_runtime = "tokio")]
impl PairHostHandle {
    /// Pop one queued event for Swift. Returns `None` when the queue is
    /// empty.
    pub async fn poll_event(&self) -> Option<PairEvent> {
        self.events.pop().await
    }

    /// Provide the Mac's NI discovery token. May be called either before
    /// any iPhone connects (the value is stashed in a placeholder slot and
    /// transferred to the next session at hello time) or while a session
    /// is active.
    pub async fn set_ni_discovery_token(&self, token_b64: String) {
        let mut guard = self.active.lock().await;
        if let Some(session) = guard.as_mut() {
            session.pending_ni_token_b64 = Some(token_b64);
        } else {
            // Pre-session stash. `out_tx` here is a placeholder that no
            // one consumes; when the next iPhone connects, `handle_incoming`
            // harvests `pending_ni_token_b64` and replaces the slot with a
            // real session whose `out_tx` is wired to its WS sink.
            let (out_tx, _out_rx) = tokio::sync::mpsc::unbounded_channel();
            *guard = Some(HostActiveSession {
                out_tx,
                pending_ni_token_b64: Some(token_b64),
                handshook: false,
            });
        }
    }

    /// Confirm or reject a pair request after the Mac UI shows its
    /// dialog. `lan_ip` is included only when `accepted` is true.
    pub async fn accept_pair_request(
        &self,
        accepted: bool,
        lan_ip: String,
        codex_port: u16,
    ) -> Result<(), PairError> {
        let guard = self.active.lock().await;
        let Some(session) = guard.as_ref() else {
            return Err(PairError::InvalidState("no active pair session".into()));
        };
        if !session.handshook {
            return Err(PairError::InvalidState(
                "cannot answer pair request before hello handshake".into(),
            ));
        }
        let msg = if accepted {
            PairWireMessage::PairAccept {
                codex_ws_url: format!("ws://{lan_ip}:{codex_port}"),
                lan_ip,
            }
        } else {
            PairWireMessage::PairReject { reason: None }
        };
        session
            .out_tx
            .send(msg)
            .map_err(|err| PairError::Transport(err.to_string()))?;
        Ok(())
    }

    /// Stop accepting new pair connections, drop any active session, and
    /// shut down the WS listener.
    pub async fn stop(&self) {
        if let Some(handle) = self.listener_task.lock().await.take() {
            handle.abort();
        }
        let mut guard = self.active.lock().await;
        *guard = None;
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

/// Start the Mac-side pair host. Binds an OS-assigned TCP port, returns
/// the bound port + suggested TXT entries so Swift can publish a Bonjour
/// service. The handle owns the listener and any in-flight pair session.
pub async fn start_pair_host(
    device_name: String,
    mac_id: String,
    codex_port: u16,
) -> Result<(Arc<PairHostHandle>, PairServiceInfo), PairError> {
    let listener = TcpListener::bind("0.0.0.0:0")
        .await
        .map_err(|err| PairError::Transport(format!("bind pair listener: {err}")))?;
    let local_addr = listener
        .local_addr()
        .map_err(|err| PairError::Transport(format!("local_addr: {err}")))?;
    let port = local_addr.port();

    let events = Arc::new(EventQueue::default());
    let active: Arc<Mutex<Option<HostActiveSession>>> = Arc::new(Mutex::new(None));

    let listener_events = Arc::clone(&events);
    let listener_active = Arc::clone(&active);
    let listener_task = tokio::spawn(async move {
        loop {
            let (stream, peer_addr) = match listener.accept().await {
                Ok(pair) => pair,
                Err(err) => {
                    warn!("pair: listener accept failed: {err}");
                    continue;
                }
            };
            debug!("pair: incoming connection from {peer_addr}");
            let events = Arc::clone(&listener_events);
            let active = Arc::clone(&listener_active);
            tokio::spawn(async move {
                if let Err(err) = handle_incoming(stream, events, active).await {
                    warn!("pair: incoming session ended with error: {err}");
                }
            });
        }
    });

    let handle = Arc::new(PairHostHandle {
        listener_task: Mutex::new(Some(listener_task)),
        active,
        events,
        port,
    });

    Ok((
        handle,
        PairServiceInfo {
            service_name: format!("Litter on {device_name}"),
            port,
            txt_entries: vec![
                "v=1".to_string(),
                format!("mac-id={mac_id}"),
                format!("codex-port={codex_port}"),
            ],
        },
    ))
}

async fn handle_incoming(
    stream: TcpStream,
    events: Arc<EventQueue>,
    active: Arc<Mutex<Option<HostActiveSession>>>,
) -> Result<(), PairError> {
    let ws = accept_async(stream)
        .await
        .map_err(|err| PairError::Transport(format!("ws upgrade: {err}")))?;
    let (mut sink, mut stream) = ws.split();

    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<PairWireMessage>();

    // Pre-existing token stash from the Mac side (set before any iPhone
    // arrived). We harvest it under the lock and replace the session with a
    // fresh one bound to this connection.
    let mut session = HostActiveSession {
        out_tx: out_tx.clone(),
        pending_ni_token_b64: None,
        handshook: false,
    };
    {
        let mut guard = active.lock().await;
        if let Some(prev) = guard.take() {
            session.pending_ni_token_b64 = prev.pending_ni_token_b64;
        }
        *guard = Some(session);
    }

    // Writer task: drains outbound queue → WS sink.
    let writer = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if let Err(err) = send_wire(&mut sink, &msg).await {
                warn!("pair host writer: {err}");
                break;
            }
            // Closing-side messages: stop after sending so we don't queue
            // up further chatter against a half-dead peer.
            if matches!(
                msg,
                PairWireMessage::PairAccept { .. } | PairWireMessage::PairReject { .. }
            ) {
                let _ = sink.close().await;
                break;
            }
        }
    });

    // Reader loop: WS → events. Each message either triggers a host event
    // or, for hello, a synchronous hello_ack reply.
    while let Some(frame) = stream.next().await {
        let frame = match frame {
            Ok(f) => f,
            Err(err) => {
                events
                    .push(PairEvent::Disconnected {
                        reason: err.to_string(),
                    })
                    .await;
                break;
            }
        };
        match frame {
            WsMessage::Text(text) => {
                let parsed = match parse_wire(text.as_str()) {
                    Ok(m) => m,
                    Err(err) => {
                        warn!("pair host: bad frame: {err}");
                        continue;
                    }
                };
                match parsed {
                    PairWireMessage::Hello {
                        device_name,
                        ni_discovery_token_b64,
                    } => {
                        // Reply with hello_ack carrying the Mac's stashed
                        // NI discovery token (or empty if not yet
                        // populated — Swift can call
                        // set_ni_discovery_token before this, but if the
                        // race loses we send empty and rely on the iPhone
                        // to re-send once the Mac UI re-broadcasts).
                        let ack_token = {
                            let mut guard = active.lock().await;
                            if let Some(session) = guard.as_mut() {
                                session.handshook = true;
                                session.pending_ni_token_b64.clone().unwrap_or_default()
                            } else {
                                String::new()
                            }
                        };
                        if let Err(err) = out_tx.send(PairWireMessage::HelloAck {
                            ni_discovery_token_b64: ack_token,
                        }) {
                            warn!("pair host: hello_ack send failed: {err}");
                        }
                        events
                            .push(PairEvent::HostPeerConnected {
                                device_name,
                                ni_discovery_token_b64,
                            })
                            .await;
                    }
                    PairWireMessage::PairRequest { distance_m } => {
                        events.push(PairEvent::HostPairRequest { distance_m }).await;
                    }
                    PairWireMessage::DistanceUpdate { distance_m } => {
                        events.push(PairEvent::DistanceUpdate { distance_m }).await;
                    }
                    PairWireMessage::HelloAck { .. }
                    | PairWireMessage::PairAccept { .. }
                    | PairWireMessage::PairReject { .. } => {
                        // Wrong direction; ignore.
                        debug!("pair host: ignoring unexpected wire message direction");
                    }
                }
            }
            WsMessage::Close(_) => {
                events
                    .push(PairEvent::Disconnected {
                        reason: "peer closed".into(),
                    })
                    .await;
                break;
            }
            _ => {}
        }
    }

    writer.abort();
    let mut guard = active.lock().await;
    *guard = None;
    Ok(())
}

// ── Client side (iPhone) ─────────────────────────────────────────────────

#[derive(uniffi::Object)]
pub struct PairClientHandle {
    out_tx: tokio::sync::mpsc::UnboundedSender<PairWireMessage>,
    events: Arc<EventQueue>,
    reader_task: Mutex<Option<JoinHandle<()>>>,
    writer_task: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl PairClientHandle {
    /// Pop one queued event for Swift.
    pub async fn poll_event(&self) -> Option<PairEvent> {
        self.events.pop().await
    }

    /// Periodic distance update from NISession on the iPhone. Cheap; the
    /// Mac UI may use these to render an "iPhone X.Y m away" label before
    /// the formal pair_request.
    pub fn submit_ni_distance(&self, distance_m: f32) -> Result<(), PairError> {
        self.out_tx
            .send(PairWireMessage::DistanceUpdate { distance_m })
            .map_err(|err| PairError::Transport(err.to_string()))
    }

    /// Ask the Mac to confirm pairing. `distance_m` is included for the
    /// Mac's confirm dialog.
    pub fn submit_pair_request(&self, distance_m: Option<f32>) -> Result<(), PairError> {
        self.out_tx
            .send(PairWireMessage::PairRequest { distance_m })
            .map_err(|err| PairError::Transport(err.to_string()))
    }

    /// Tear down the WS connection.
    pub async fn stop(&self) {
        if let Some(handle) = self.reader_task.lock().await.take() {
            handle.abort();
        }
        if let Some(handle) = self.writer_task.lock().await.take() {
            handle.abort();
        }
    }
}

/// Open a WebSocket from the iPhone to the Mac's pair host, send hello,
/// and return a handle the platform polls for events. The handshake itself
/// happens asynchronously on the spawned reader task — Swift drives state
/// purely via `poll_event`.
pub async fn pair_from_iphone(
    host: String,
    port: u16,
    device_name: String,
    ni_discovery_token_b64: String,
) -> Result<Arc<PairClientHandle>, PairError> {
    let url = format!("ws://{host}:{port}");
    let (ws, _) = connect_async(&url)
        .await
        .map_err(|err| PairError::Transport(format!("connect {url}: {err}")))?;
    info!("pair: iphone connected to {url}");
    let (sink, mut stream) = ws.split();

    let events = Arc::new(EventQueue::default());
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<PairWireMessage>();

    // Push the initial hello immediately. Swift cannot meaningfully
    // observe hello-send timing, so we do it inline.
    out_tx
        .send(PairWireMessage::Hello {
            device_name,
            ni_discovery_token_b64,
        })
        .map_err(|err| PairError::Transport(err.to_string()))?;

    let writer_events = Arc::clone(&events);
    let writer_task = tokio::spawn(async move {
        let mut sink = sink;
        while let Some(msg) = out_rx.recv().await {
            if let Err(err) = send_wire(&mut sink, &msg).await {
                writer_events
                    .push(PairEvent::Disconnected {
                        reason: err.to_string(),
                    })
                    .await;
                break;
            }
        }
    });

    let reader_events = Arc::clone(&events);
    let reader_task = tokio::spawn(async move {
        while let Some(frame) = stream.next().await {
            let frame = match frame {
                Ok(f) => f,
                Err(err) => {
                    reader_events
                        .push(PairEvent::Disconnected {
                            reason: err.to_string(),
                        })
                        .await;
                    break;
                }
            };
            match frame {
                WsMessage::Text(text) => {
                    let parsed = match parse_wire(text.as_str()) {
                        Ok(m) => m,
                        Err(err) => {
                            warn!("pair client: bad frame: {err}");
                            continue;
                        }
                    };
                    match parsed {
                        PairWireMessage::HelloAck {
                            ni_discovery_token_b64,
                        } => {
                            reader_events
                                .push(PairEvent::ClientPeerAccepted {
                                    ni_discovery_token_b64,
                                })
                                .await;
                        }
                        PairWireMessage::PairAccept {
                            codex_ws_url,
                            lan_ip,
                        } => {
                            reader_events
                                .push(PairEvent::ClientPairAccepted {
                                    codex_ws_url,
                                    lan_ip,
                                })
                                .await;
                            // Mac will close after sending; break out of
                            // the read loop to avoid blocking on a closed
                            // socket.
                            break;
                        }
                        PairWireMessage::PairReject { reason } => {
                            reader_events.push(PairEvent::PeerRejected { reason }).await;
                            break;
                        }
                        PairWireMessage::Hello { .. }
                        | PairWireMessage::PairRequest { .. }
                        | PairWireMessage::DistanceUpdate { .. } => {
                            debug!("pair client: ignoring unexpected wire message direction");
                        }
                    }
                }
                WsMessage::Close(_) => {
                    reader_events
                        .push(PairEvent::Disconnected {
                            reason: "peer closed".into(),
                        })
                        .await;
                    break;
                }
                _ => {}
            }
        }
    });

    Ok(Arc::new(PairClientHandle {
        out_tx,
        events,
        reader_task: Mutex::new(Some(reader_task)),
        writer_task: Mutex::new(Some(writer_task)),
    }))
}
