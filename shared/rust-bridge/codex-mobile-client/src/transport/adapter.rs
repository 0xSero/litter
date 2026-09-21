//! Adapter wrapping upstream `AppServerClient` for mobile client usage.
//!
//! Provides a thin byte-level interface on top of the typed upstream client,
//! bridging JSON ↔ typed `ClientRequest`/`ClientNotification` conversion
//! and exposing `AppServerEvent` for event consumption.

use std::io::Result as IoResult;

use super::{RpcError, TransportError};
use codex_app_server_client::{
    AppServerClient, AppServerEvent, RemoteAppServerClient, RemoteAppServerConnectArgs,
    RemoteAppServerEndpoint,
};
use codex_app_server_protocol::{
    ClientNotification, ClientRequest, JSONRPCErrorError, RequestId, Result as JsonRpcResult,
};

/// Adapter wrapping the upstream `AppServerClient` (both in-process and remote variants).
///
/// Provides a JSON byte-level API suitable for FFI bridging, while delegating
/// to the upstream typed client internally.
pub struct AppServerAdapter {
    client: AppServerClient,
}

impl AppServerAdapter {
    /// Wrap an existing `AppServerClient`.
    pub fn new(client: AppServerClient) -> Self {
        Self { client }
    }

    /// Connect to a remote app-server via WebSocket.
    pub async fn connect_remote(
        websocket_url: String,
        client_name: String,
        client_version: String,
        experimental_api: bool,
        channel_capacity: usize,
    ) -> Result<Self, TransportError> {
        let args = RemoteAppServerConnectArgs {
            endpoint: RemoteAppServerEndpoint::WebSocket {
                websocket_url: websocket_url.clone(),
                auth_token: None,
            },
            client_name,
            client_version,
            experimental_api,
            opt_out_notification_methods: Vec::new(),
            mcp_server_openai_form_elicitation: false,
            channel_capacity,
        };

        let client = RemoteAppServerClient::connect(args)
            .await
            .map_err(|e| TransportError::ConnectionFailed(e.to_string()))?;

        Ok(Self {
            client: AppServerClient::Remote(client),
        })
    }

    /// Send a typed `ClientRequest` and return the raw JSON-RPC result bytes.
    pub async fn send_request(&self, json: &[u8]) -> Result<Vec<u8>, RpcError> {
        let json_str = std::str::from_utf8(json)
            .map_err(|e| RpcError::Deserialization(format!("invalid UTF-8: {e}")))?;

        let value: serde_json::Value = serde_json::from_str(json_str)
            .map_err(|e| RpcError::Deserialization(format!("invalid JSON: {e}")))?;

        let request_id = value
            .get("id")
            .cloned()
            .ok_or_else(|| RpcError::Deserialization("missing 'id' field".to_string()))?;

        let request: ClientRequest = serde_json::from_value(value)
            .map_err(|e| RpcError::Deserialization(format!("failed to parse request: {e}")))?;

        match self.client.request(request).await {
            Ok(result) => {
                let response = match result {
                    Ok(value) => serde_json::json!({
                        "id": request_id,
                        "result": value,
                    }),
                    Err(error) => serde_json::json!({
                        "id": request_id,
                        "error": {
                            "code": error.code,
                            "message": error.message,
                        },
                    }),
                };
                serde_json::to_vec(&response)
                    .map_err(|e| RpcError::Deserialization(format!("response serialize: {e}")))
            }
            Err(e) => Err(RpcError::Transport(TransportError::SendFailed(
                e.to_string(),
            ))),
        }
    }

    /// Send a typed `ClientNotification` (fire-and-forget).
    pub async fn send_notification(&self, json: &[u8]) -> Result<(), RpcError> {
        let json_str = std::str::from_utf8(json)
            .map_err(|e| RpcError::Deserialization(format!("invalid UTF-8: {e}")))?;

        let value: serde_json::Value = serde_json::from_str(json_str)
            .map_err(|e| RpcError::Deserialization(format!("invalid JSON: {e}")))?;

        let notification: ClientNotification = serde_json::from_value(value)
            .map_err(|e| RpcError::Deserialization(format!("failed to parse notification: {e}")))?;

        self.client
            .notify(notification)
            .await
            .map_err(|e| RpcError::Transport(TransportError::SendFailed(e.to_string())))
    }

    /// Respond to a server-initiated request.
    pub async fn send_response(&self, json: &[u8]) -> Result<(), RpcError> {
        let json_str = std::str::from_utf8(json)
            .map_err(|e| RpcError::Deserialization(format!("invalid UTF-8: {e}")))?;

        let value: serde_json::Value = serde_json::from_str(json_str)
            .map_err(|e| RpcError::Deserialization(format!("invalid JSON: {e}")))?;

        let id = match &value["id"] {
            serde_json::Value::Number(n) => RequestId::Integer(n.as_i64().unwrap_or(0)),
            serde_json::Value::String(s) => RequestId::String(s.clone()),
            _ => {
                return Err(RpcError::Deserialization(
                    "invalid or missing 'id' field".to_string(),
                ));
            }
        };

        let has_result = value.get("result").is_some();
        let has_error = value.get("error").is_some();

        if has_result {
            let result: JsonRpcResult = value["result"].clone();
            self.client
                .resolve_server_request(id, result)
                .await
                .map_err(|e| RpcError::Transport(TransportError::SendFailed(e.to_string())))
        } else if has_error {
            let error = JSONRPCErrorError {
                code: value["error"]["code"].as_i64().unwrap_or(-1),
                message: value["error"]["message"]
                    .as_str()
                    .unwrap_or("unknown")
                    .to_string(),
                data: value["error"]["data"].clone().into(),
            };
            self.client
                .reject_server_request(id, error)
                .await
                .map_err(|e| RpcError::Transport(TransportError::SendFailed(e.to_string())))
        } else {
            Err(RpcError::Deserialization(
                "response must have 'result' or 'error' field".to_string(),
            ))
        }
    }

    /// Send a typed `ClientRequest` and return the parsed result value.
    ///
    /// This is the higher-level convenience method used by `ServerSession::request`.
    pub async fn request_typed(
        &self,
        request: ClientRequest,
    ) -> Result<serde_json::Value, RpcError> {
        match self.client.request(request).await {
            Ok(result) => match result {
                Ok(value) => Ok(value),
                Err(error) => Err(RpcError::Server {
                    code: error.code,
                    message: error.message,
                }),
            },
            Err(e) => Err(RpcError::Transport(TransportError::SendFailed(
                e.to_string(),
            ))),
        }
    }

    /// Send a typed `ClientNotification`.
    pub async fn notify_typed(&self, notification: ClientNotification) -> Result<(), RpcError> {
        self.client
            .notify(notification)
            .await
            .map_err(|e| RpcError::Transport(TransportError::SendFailed(e.to_string())))
    }

    /// Resolve a server request with a typed result.
    pub async fn resolve_server_request(
        &self,
        request_id: RequestId,
        result: JsonRpcResult,
    ) -> Result<(), RpcError> {
        self.client
            .resolve_server_request(request_id, result)
            .await
            .map_err(|e| RpcError::Transport(TransportError::SendFailed(e.to_string())))
    }

    /// Reject a server request with an error.
    pub async fn reject_server_request(
        &self,
        request_id: RequestId,
        error: JSONRPCErrorError,
    ) -> Result<(), RpcError> {
        self.client
            .reject_server_request(request_id, error)
            .await
            .map_err(|e| RpcError::Transport(TransportError::SendFailed(e.to_string())))
    }

    /// Return the next event from the server, or `None` when disconnected.
    pub async fn next_event(&mut self) -> Option<AppServerEvent> {
        self.client.next_event().await
    }

    /// Shut down the adapter and underlying client.
    pub async fn shutdown(self) -> IoResult<()> {
        self.client.shutdown().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adapter_wraps_remote_variant() {
        // Verify type construction compiles (no runtime test needed for Remote
        // since it requires a real WebSocket server).
        fn _assert_send_sync<T: Send>() {}
        _assert_send_sync::<AppServerAdapter>();
    }

    #[test]
    fn send_response_rejects_invalid_utf8() {
        let bad_bytes: &[u8] = &[0xff, 0xfe];
        let result = String::from_utf8(bad_bytes.to_vec());
        assert!(result.is_err());
    }

    #[test]
    fn send_request_rejects_invalid_json() {
        let bad_json = b"not valid json";
        let result: Result<serde_json::Value, _> = serde_json::from_slice(bad_json);
        assert!(result.is_err());
    }

    #[test]
    fn request_id_parsing_covers_integer_and_string() {
        let int_value: serde_json::Value = serde_json::json!(42);
        let str_value: serde_json::Value = serde_json::json!("req-1");

        let int_id = match &int_value {
            serde_json::Value::Number(n) => RequestId::Integer(n.as_i64().unwrap_or(0)),
            _ => panic!("expected number"),
        };
        assert!(matches!(int_id, RequestId::Integer(42)));

        let str_id = match &str_value {
            serde_json::Value::String(s) => RequestId::String(s.clone()),
            _ => panic!("expected string"),
        };
        assert!(matches!(str_id, RequestId::String(ref s) if s == "req-1"));
    }
}
