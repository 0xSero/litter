//! Transport layer: adapter over upstream `AppServerClient`.
//!
//! Provides `AppServerAdapter` wrapping `codex-app-server-client`'s
//! `AppServerClient` (both in-process and remote variants), plus shared
//! error types consumed by session and facade layers.

pub mod adapter;

/// Errors from transport operations.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("connection failed: {0}")]
    ConnectionFailed(String),
    #[error("send failed: {0}")]
    SendFailed(String),
    #[error("receive failed: {0}")]
    ReceiveFailed(String),
    #[error("timeout")]
    Timeout,
    #[error("disconnected")]
    Disconnected,
    #[error("tls error: {0}")]
    Tls(String),
}

/// RPC-level errors.
#[derive(Debug, thiserror::Error)]
pub enum RpcError {
    #[error("transport error: {0}")]
    Transport(#[from] TransportError),
    #[error("server error {code}: {message}")]
    Server { code: i64, message: String },
    #[error("deserialization failed: {0}")]
    Deserialization(String),
    #[error("request cancelled")]
    Cancelled,
    #[error("request timed out")]
    Timeout,
}
