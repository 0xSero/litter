use std::pin::Pin;
use std::str::FromStr;
use std::sync::Arc;
use std::task::{Context, Poll};

use async_trait::async_trait;
use codex_app_server_client::{AppServerClient, RemoteAppServerClient, RemoteAppServerConnectArgs};
use iroh::endpoint::{IdleTimeout, QuicTransportConfig, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayUrl};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tracing::info;

use crate::session::remote_transport::{Reconnected, RemoteTransport};
use crate::transport::TransportError;
use crate::types::AgentRuntimeKind;

pub const ALLEYCAT_PROTOCOL_VERSION: u32 = 1;
pub const ALLEYCAT_ALPN: &[u8] = b"alleycat/1";
const MAX_FRAME_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedPairPayload {
    pub version: u32,
    pub node_id: String,
    pub token: String,
    pub relay: Option<String>,
    pub host_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentInfo {
    pub name: String,
    pub display_name: String,
    pub wire: AgentWire,
    pub available: bool,
}

pub fn agent_runtime_kind(name: &str, display_name: &str) -> Option<AgentRuntimeKind> {
    let name = name.trim().to_ascii_lowercase();
    let display_name = display_name.trim().to_ascii_lowercase();
    let candidate = if name.is_empty() {
        display_name.as_str()
    } else {
        name.as_str()
    };
    match candidate {
        "codex" => Some(AgentRuntimeKind::Codex),
        "pi" | "pi.dev" | "pidev" => Some(AgentRuntimeKind::Pi),
        "opencode" | "open-code" | "open_code" => Some(AgentRuntimeKind::Opencode),
        "claude" | "claude-code" | "claude_code" => Some(AgentRuntimeKind::Claude),
        _ if display_name == "codex" => Some(AgentRuntimeKind::Codex),
        _ if display_name == "pi" || display_name == "pi.dev" => Some(AgentRuntimeKind::Pi),
        _ if display_name == "opencode" || display_name == "open code" => {
            Some(AgentRuntimeKind::Opencode)
        }
        _ if display_name == "claude" || display_name == "claude code" => {
            Some(AgentRuntimeKind::Claude)
        }
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentWire {
    Websocket,
    Jsonl,
}

#[derive(Debug, Clone)]
pub struct AlleycatReconnectTransport {
    pub params: ParsedPairPayload,
    pub agent: String,
    pub wire: AgentWire,
}

#[async_trait]
impl RemoteTransport for AlleycatReconnectTransport {
    async fn reconnect(
        &self,
        _args: &RemoteAppServerConnectArgs,
        _websocket_url: &str,
    ) -> Result<Reconnected, TransportError> {
        // Each successful reconnect creates a fresh iroh Endpoint inside a new
        // AlleycatSession. The worker stores that AlleycatSession as its keepalive
        // so the previous endpoint is dropped only after the new one is installed —
        // the previous behavior of dropping the new session immediately would have
        // torn down the QUIC connection backing the new client.
        let (client, session) =
            connect_app_server_client(self.params.clone(), self.agent.clone(), self.wire)
                .await
                .map_err(|error| TransportError::ConnectionFailed(error.to_string()))?;
        Ok(Reconnected {
            client,
            keepalive: Some(session as Arc<dyn Send + Sync>),
        })
    }
}

pub struct AlleycatSession {
    #[allow(dead_code)]
    endpoint: Endpoint,
    pub params: ParsedPairPayload,
    pub agent: String,
    pub wire: AgentWire,
}

#[derive(Debug, thiserror::Error)]
pub enum AlleycatError {
    #[error("invalid pair payload: {0}")]
    InvalidPayload(String),
    #[error("protocol version mismatch: payload={payload} client={client}")]
    ProtocolMismatch { payload: u32, client: u32 },
    #[error("transport error: {0}")]
    Transport(String),
}

#[derive(Debug, Deserialize)]
struct PairPayloadWire {
    v: u32,
    node_id: String,
    token: String,
    relay: Option<String>,
    #[serde(default, alias = "hostname", alias = "display_name", alias = "name")]
    host_name: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    ListAgents {
        v: u32,
        token: String,
    },
    Connect {
        v: u32,
        token: String,
        agent: String,
    },
}

#[derive(Debug, Deserialize)]
struct Response {
    v: u32,
    ok: bool,
    #[serde(default)]
    agents: Vec<AgentInfoWire>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AgentInfoWire {
    name: String,
    display_name: String,
    wire: AgentWireWire,
    available: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AgentWireWire {
    Websocket,
    Jsonl,
}

pub fn parse_pair_payload(json: &str) -> Result<ParsedPairPayload, AlleycatError> {
    let wire: PairPayloadWire = serde_json::from_str(json)
        .map_err(|error| AlleycatError::InvalidPayload(format!("malformed JSON: {error}")))?;
    if wire.v != ALLEYCAT_PROTOCOL_VERSION {
        return Err(AlleycatError::ProtocolMismatch {
            payload: wire.v,
            client: ALLEYCAT_PROTOCOL_VERSION,
        });
    }
    if wire.node_id.trim().is_empty() {
        return Err(AlleycatError::InvalidPayload("empty node_id".into()));
    }
    EndpointId::from_str(&wire.node_id)
        .map_err(|error| AlleycatError::InvalidPayload(format!("invalid node_id: {error}")))?;
    if wire.token.trim().is_empty() {
        return Err(AlleycatError::InvalidPayload("empty token".into()));
    }
    if let Some(relay) = wire.relay.as_deref() {
        RelayUrl::from_str(relay).map_err(|error| {
            AlleycatError::InvalidPayload(format!("invalid relay URL: {error}"))
        })?;
    }
    Ok(ParsedPairPayload {
        version: wire.v,
        node_id: wire.node_id,
        token: wire.token,
        relay: wire.relay,
        host_name: normalize_optional_host_name(wire.host_name),
    })
}

fn normalize_optional_host_name(host_name: Option<String>) -> Option<String> {
    host_name
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
}

pub async fn list_agents(params: ParsedPairPayload) -> Result<Vec<AgentInfo>, AlleycatError> {
    let (_endpoint, _conn, mut send, mut recv) = open_stream(&params).await?;
    write_json_frame(
        &mut send,
        &Request::ListAgents {
            v: ALLEYCAT_PROTOCOL_VERSION,
            token: params.token.clone(),
        },
    )
    .await?;
    let response: Response = read_json_frame(&mut recv).await?;
    validate_response(&response)?;
    Ok(response
        .agents
        .into_iter()
        .map(|agent| AgentInfo {
            name: agent.name,
            display_name: agent.display_name,
            wire: agent.wire.into(),
            available: agent.available,
        })
        .collect())
}

pub async fn connect_app_server_client(
    params: ParsedPairPayload,
    agent: String,
    wire: AgentWire,
) -> Result<(AppServerClient, Arc<AlleycatSession>), AlleycatError> {
    let (endpoint, _conn, mut send, mut recv) = open_stream(&params).await?;
    write_json_frame(
        &mut send,
        &Request::Connect {
            v: ALLEYCAT_PROTOCOL_VERSION,
            token: params.token.clone(),
            agent: agent.clone(),
        },
    )
    .await?;
    let response: Response = read_json_frame(&mut recv).await?;
    validate_response(&response)?;
    let label = format!("alleycat://{}/{}", params.node_id, agent);
    let args = RemoteAppServerConnectArgs {
        websocket_url: format!("ws://alleycat/{agent}"),
        auth_token: None,
        client_name: "Litter".to_string(),
        client_version: "1.0".to_string(),
        experimental_api: true,
        opt_out_notification_methods: Vec::new(),
        channel_capacity: 256,
    };
    let stream = AlleycatStream::new(send, recv);
    let remote = match wire {
        AgentWire::Websocket => {
            RemoteAppServerClient::connect_websocket_stream(stream, args, label)
                .await
                .map_err(|error| AlleycatError::Transport(error.to_string()))?
        }
        AgentWire::Jsonl => RemoteAppServerClient::connect_json_line_stream(stream, args, label)
            .await
            .map_err(|error| AlleycatError::Transport(error.to_string()))?,
    };
    let session = Arc::new(AlleycatSession {
        endpoint,
        params,
        agent,
        wire,
    });
    Ok((AppServerClient::Remote(remote), session))
}

async fn open_stream(
    params: &ParsedPairPayload,
) -> Result<(Endpoint, iroh::endpoint::Connection, SendStream, RecvStream), AlleycatError> {
    // QUIC's effective idle timeout is min(local, remote) — leaving the
    // phone on iroh's 30s default would cap pi/opencode tunnels at 30s
    // even though the daemon raised its own to 600s, killing idle agent
    // connections between user actions. Match the daemon's 600s so the
    // tunnels stay open until either side actually wants to close them.
    let idle_timeout = IdleTimeout::try_from(std::time::Duration::from_secs(600))
        .map_err(|err| AlleycatError::Transport(format!("idle timeout: {err}")))?;
    let transport = QuicTransportConfig::builder()
        .max_idle_timeout(Some(idle_timeout))
        .build();
    let mut endpoint_builder =
        Endpoint::builder(iroh::endpoint::presets::N0).transport_config(transport);
    #[cfg(target_os = "android")]
    {
        endpoint_builder = endpoint_builder
            .dns_resolver(iroh::dns::DnsResolver::with_nameserver(
                std::net::SocketAddr::from(([8, 8, 8, 8], 53)),
            ))
            .ca_roots_config(iroh::tls::CaRootsConfig::embedded());
    }
    let endpoint = endpoint_builder
        .bind()
        .await
        .map_err(|error| AlleycatError::Transport(format!("binding iroh endpoint: {error}")))?;
    let id = EndpointId::from_str(&params.node_id)
        .map_err(|error| AlleycatError::InvalidPayload(format!("invalid node_id: {error}")))?;
    let mut addr = EndpointAddr::new(id);
    if let Some(relay) = params.relay.as_deref() {
        let relay = RelayUrl::from_str(relay).map_err(|error| {
            AlleycatError::InvalidPayload(format!("invalid relay URL: {error}"))
        })?;
        addr = addr.with_relay_url(relay);
    }
    info!("alleycat: connecting node_id={}", params.node_id);
    let conn = endpoint
        .connect(addr, ALLEYCAT_ALPN)
        .await
        .map_err(|error| AlleycatError::Transport(format!("connecting iroh endpoint: {error}")))?;
    let (send, recv) = conn
        .open_bi()
        .await
        .map_err(|error| AlleycatError::Transport(format!("opening iroh stream: {error}")))?;
    Ok((endpoint, conn, send, recv))
}

async fn read_json_frame<T, R>(reader: &mut R) -> Result<T, AlleycatError>
where
    T: for<'de> Deserialize<'de>,
    R: AsyncRead + Unpin,
{
    let len = reader
        .read_u32()
        .await
        .map_err(|error| AlleycatError::Transport(format!("reading frame length: {error}")))?
        as usize;
    if len > MAX_FRAME_BYTES {
        return Err(AlleycatError::Transport(format!(
            "frame too large: {len} bytes"
        )));
    }
    let mut buf = vec![0u8; len];
    reader
        .read_exact(&mut buf)
        .await
        .map_err(|error| AlleycatError::Transport(format!("reading frame body: {error}")))?;
    serde_json::from_slice(&buf)
        .map_err(|error| AlleycatError::Transport(format!("decoding frame JSON: {error}")))
}

async fn write_json_frame<T, W>(writer: &mut W, value: &T) -> Result<(), AlleycatError>
where
    T: Serialize,
    W: AsyncWrite + Unpin,
{
    let buf = serde_json::to_vec(value)
        .map_err(|error| AlleycatError::Transport(format!("encoding frame JSON: {error}")))?;
    if buf.len() > MAX_FRAME_BYTES {
        return Err(AlleycatError::Transport(format!(
            "frame too large: {} bytes",
            buf.len()
        )));
    }
    writer
        .write_u32(buf.len() as u32)
        .await
        .map_err(|error| AlleycatError::Transport(format!("writing frame length: {error}")))?;
    writer
        .write_all(&buf)
        .await
        .map_err(|error| AlleycatError::Transport(format!("writing frame body: {error}")))?;
    writer
        .flush()
        .await
        .map_err(|error| AlleycatError::Transport(format!("flushing frame: {error}")))?;
    Ok(())
}

fn validate_response(response: &Response) -> Result<(), AlleycatError> {
    if response.v != ALLEYCAT_PROTOCOL_VERSION {
        return Err(AlleycatError::ProtocolMismatch {
            payload: response.v,
            client: ALLEYCAT_PROTOCOL_VERSION,
        });
    }
    if !response.ok {
        return Err(AlleycatError::Transport(
            response
                .error
                .clone()
                .unwrap_or_else(|| "host rejected request".to_string()),
        ));
    }
    Ok(())
}

impl From<AgentWireWire> for AgentWire {
    fn from(value: AgentWireWire) -> Self {
        match value {
            AgentWireWire::Websocket => Self::Websocket,
            AgentWireWire::Jsonl => Self::Jsonl,
        }
    }
}

#[derive(Debug)]
struct AlleycatStream {
    send: SendStream,
    recv: RecvStream,
}

impl AlleycatStream {
    fn new(send: SendStream, recv: RecvStream) -> Self {
        Self { send, recv }
    }
}

impl AsyncRead for AlleycatStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        Pin::new(&mut this.recv).poll_read(cx, buf)
    }
}

impl AsyncWrite for AlleycatStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let this = self.get_mut();
        AsyncWrite::poll_write(Pin::new(&mut this.send), cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        AsyncWrite::poll_flush(Pin::new(&mut this.send), cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        AsyncWrite::poll_shutdown(Pin::new(&mut this.send), cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_pair_payload_happy_path() {
        let key = iroh::SecretKey::generate();
        let json = format!(
            r#"{{"v":1,"node_id":"{}","token":"deadbeef","relay":"https://relay.example.com","host_name":"studio.local"}}"#,
            key.public()
        );
        let parsed = parse_pair_payload(&json).expect("parse");
        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.node_id, key.public().to_string());
        assert_eq!(parsed.token, "deadbeef");
        assert_eq!(parsed.relay.as_deref(), Some("https://relay.example.com"));
        assert_eq!(parsed.host_name.as_deref(), Some("studio.local"));
    }

    #[test]
    fn parse_pair_payload_accepts_legacy_hostname_alias() {
        let key = iroh::SecretKey::generate();
        let json = format!(
            r#"{{"v":1,"node_id":"{}","token":"deadbeef","hostname":"studio"}}"#,
            key.public()
        );
        let parsed = parse_pair_payload(&json).expect("parse");
        assert_eq!(parsed.host_name.as_deref(), Some("studio"));
    }

    #[test]
    fn parse_pair_payload_rejects_bad_node_id() {
        let err = parse_pair_payload(r#"{"v":1,"node_id":"nope","token":"deadbeef"}"#)
            .unwrap_err()
            .to_string();
        assert!(err.contains("invalid node_id"));
    }

    #[test]
    fn agent_runtime_kind_maps_known_agents() {
        assert_eq!(
            agent_runtime_kind("codex", "Codex"),
            Some(AgentRuntimeKind::Codex)
        );
        assert_eq!(
            agent_runtime_kind("pi.dev", "Pi"),
            Some(AgentRuntimeKind::Pi)
        );
        assert_eq!(
            agent_runtime_kind("open-code", "opencode"),
            Some(AgentRuntimeKind::Opencode)
        );
        assert_eq!(
            agent_runtime_kind("claude-code", "Claude"),
            Some(AgentRuntimeKind::Claude)
        );
    }

    #[test]
    fn agent_runtime_kind_ignores_unknown_agents() {
        assert_eq!(agent_runtime_kind("custom", "Custom"), None);
    }

    /// `AlleycatReconnectTransport` must coerce to `Arc<dyn RemoteTransport>`
    /// — that's how the worker's reconnect plumbing receives it. This is a
    /// pure type-check test: it compiles iff the trait impl stays object-safe.
    #[test]
    fn alleycat_reconnect_transport_coerces_to_trait_object() {
        let key = iroh::SecretKey::generate();
        let params = ParsedPairPayload {
            version: ALLEYCAT_PROTOCOL_VERSION,
            node_id: key.public().to_string(),
            token: "deadbeef".into(),
            relay: None,
            host_name: None,
        };
        let transport = AlleycatReconnectTransport {
            params,
            agent: "codex".into(),
            wire: AgentWire::Websocket,
        };
        let _erased: Arc<dyn RemoteTransport> = Arc::new(transport);
    }
}
