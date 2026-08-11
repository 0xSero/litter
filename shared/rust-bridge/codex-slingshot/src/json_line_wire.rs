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
        serde_json::from_str::<JSONRPCMessage>(&line)
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
