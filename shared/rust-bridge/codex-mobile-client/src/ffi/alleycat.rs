use crate::alleycat::{
    AgentCapabilities, AgentInfo, AgentPresentation, AgentWire, AlleycatError, ParsedPairPayload,
};
use crate::ffi::ClientError;

#[derive(uniffi::Object)]
pub struct AlleycatBridge;

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppAlleycatPairPayload {
    pub v: u32,
    pub node_id: String,
    pub token: String,
    pub relay: Option<String>,
    pub host_name: Option<String>,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppAlleycatAgentWire {
    Websocket,
    Jsonl,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppAlleycatAgentInfo {
    pub name: String,
    pub display_name: String,
    pub runtime_kind: Option<crate::types::AgentRuntimeKind>,
    pub wire: AppAlleycatAgentWire,
    pub available: bool,
    /// UI hints sourced from the alleycat host: title, beta badge,
    /// sort order, aliases. Absent on legacy hosts — clients fall back
    /// to generic rendering keyed off `name` / `display_name`.
    pub presentation: Option<AppAgentPresentation>,
    /// Behavioral capability flags surfaced to platform UI so it can
    /// branch without hardcoding agent names. Absent on legacy hosts.
    pub capabilities: Option<AppAgentCapabilities>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppAgentPresentation {
    pub title: Option<String>,
    pub is_beta: bool,
    pub sort_order: i32,
    pub description: Option<String>,
    pub aliases: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppAgentCapabilities {
    pub locks_reasoning_effort_after_activity: bool,
    pub visible_modes: Option<Vec<String>>,
    pub supports_ssh_bridge: bool,
    pub uses_direct_codex_port: bool,
    pub supports_thread_permission_overrides: bool,
    pub reports_effective_thread_permissions: bool,
}

impl From<AgentPresentation> for AppAgentPresentation {
    fn from(value: AgentPresentation) -> Self {
        AppAgentPresentation {
            title: value.title,
            is_beta: value.is_beta,
            sort_order: value.sort_order,
            description: value.description,
            aliases: value.aliases,
        }
    }
}

impl From<AgentCapabilities> for AppAgentCapabilities {
    fn from(value: AgentCapabilities) -> Self {
        AppAgentCapabilities {
            locks_reasoning_effort_after_activity: value.locks_reasoning_effort_after_activity,
            visible_modes: value.visible_modes,
            supports_ssh_bridge: value.supports_ssh_bridge,
            uses_direct_codex_port: value.uses_direct_codex_port,
            supports_thread_permission_overrides: value.supports_thread_permission_overrides,
            reports_effective_thread_permissions: value.reports_effective_thread_permissions,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppAlleycatConnectResult {
    pub server_id: String,
    pub node_id: String,
    pub agent_name: String,
}

#[uniffi::export]
impl AlleycatBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self
    }

    pub fn parse_pair_payload(&self, json: String) -> Result<AppAlleycatPairPayload, ClientError> {
        let parsed = crate::alleycat::parse_pair_payload(&json).map_err(map_alleycat_error)?;
        Ok(parsed.into())
    }
}

pub(crate) fn map_alleycat_error(error: AlleycatError) -> ClientError {
    match error {
        AlleycatError::InvalidPayload(message) => ClientError::InvalidParams(message),
        AlleycatError::ProtocolMismatch { payload, client } => ClientError::InvalidParams(format!(
            "alleycat protocol mismatch: payload={payload} client={client}"
        )),
        AlleycatError::Rejected(message) => ClientError::Transport(message),
        AlleycatError::Transport(message) => ClientError::Transport(message),
    }
}

impl From<AppAlleycatPairPayload> for ParsedPairPayload {
    fn from(value: AppAlleycatPairPayload) -> Self {
        ParsedPairPayload {
            version: value.v,
            node_id: value.node_id,
            token: value.token,
            relay: value.relay,
            host_name: value.host_name,
        }
    }
}

impl From<ParsedPairPayload> for AppAlleycatPairPayload {
    fn from(value: ParsedPairPayload) -> Self {
        AppAlleycatPairPayload {
            v: value.version,
            node_id: value.node_id,
            token: value.token,
            relay: value.relay,
            host_name: value.host_name,
        }
    }
}

impl From<AppAlleycatAgentWire> for AgentWire {
    fn from(value: AppAlleycatAgentWire) -> Self {
        match value {
            AppAlleycatAgentWire::Websocket => Self::Websocket,
            AppAlleycatAgentWire::Jsonl => Self::Jsonl,
        }
    }
}

impl From<AgentWire> for AppAlleycatAgentWire {
    fn from(value: AgentWire) -> Self {
        match value {
            AgentWire::Websocket => Self::Websocket,
            AgentWire::Jsonl => Self::Jsonl,
        }
    }
}

impl From<AgentInfo> for AppAlleycatAgentInfo {
    fn from(value: AgentInfo) -> Self {
        let runtime_kind = crate::alleycat::agent_runtime_kind(&value.name, &value.display_name);
        AppAlleycatAgentInfo {
            name: value.name,
            display_name: value.display_name,
            runtime_kind,
            wire: value.wire.into(),
            available: value.available,
            presentation: value.presentation.map(Into::into),
            capabilities: value.capabilities.map(Into::into),
        }
    }
}
