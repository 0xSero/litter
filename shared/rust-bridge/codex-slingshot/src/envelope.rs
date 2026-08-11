use serde::{Deserialize, Serialize};

use crate::errors::SlingshotTransportError;

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum EnvelopeType {
    ClientMessage,
    ServerMessage,
    Ack,
    Ping,
    Pong,
    ClientClosed,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum KnownPongStatus {
    Active,
    #[serde(other)]
    Unknown,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RemoteControlEnvelope {
    #[serde(rename = "type")]
    pub kind: EnvelopeType,
    pub client_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub environment_id: Option<String>,
    pub sequence_id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_history: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<KnownPongStatus>,
}

impl RemoteControlEnvelope {
    pub fn validate_outbound(&self) -> Result<(), SlingshotTransportError> {
        use EnvelopeType::*;
        self.validate_common()?;
        match self.kind {
            ClientMessage => {
                require_environment_id(self)?;
                require_stream_id(self)?;
                let message = self
                    .message
                    .as_ref()
                    .ok_or(SlingshotTransportError::MissingMessage)?;
                if !message.is_object() {
                    return Err(SlingshotTransportError::InvalidClientPayload);
                }
                if self.status.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            ClientClosed => {
                require_environment_id(self)?;
                require_stream_id(self)?;
                forbid_message(self)?;
                if self.status.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            Ack => {
                require_stream_id(self)?;
                forbid_message(self)?;
                if self.status.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            Ping => {
                forbid_message(self)?;
                if self.status.is_some() || self.skip_history.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            Pong => {
                forbid_message(self)?;
                if self.skip_history.is_some() {
                    return Err(SlingshotTransportError::InvalidSkipHistory);
                }
                if self.status.is_none() {
                    return Err(SlingshotTransportError::InvalidPongStatus);
                }
            }
            ServerMessage => return Err(invalid_payload(self)),
        }
        if self.skip_history.is_some() && self.kind != ClientMessage {
            return Err(SlingshotTransportError::InvalidSkipHistory);
        }
        Ok(())
    }

    pub fn validate_inbound(&self) -> Result<(), SlingshotTransportError> {
        use EnvelopeType::*;
        self.validate_common()?;
        match self.kind {
            ServerMessage => {
                require_environment_id(self)?;
                require_stream_id(self)?;
                if self.message.is_none() {
                    return Err(SlingshotTransportError::MissingMessage);
                }
                if self.status.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            Ack => {
                require_stream_id(self)?;
                forbid_message(self)?;
                if self.status.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            Ping => {
                forbid_message(self)?;
                if self.status.is_some() || self.skip_history.is_some() {
                    return Err(invalid_payload(self));
                }
            }
            Pong => {
                forbid_message(self)?;
                if self.skip_history.is_some() {
                    return Err(SlingshotTransportError::InvalidSkipHistory);
                }
                if self.status.is_none() {
                    return Err(SlingshotTransportError::InvalidPongStatus);
                }
            }
            ClientMessage | ClientClosed => return Err(invalid_payload(self)),
        }
        if self.skip_history.is_some() && self.kind != ClientMessage {
            return Err(SlingshotTransportError::InvalidSkipHistory);
        }
        Ok(())
    }

    fn validate_common(&self) -> Result<(), SlingshotTransportError> {
        if self.sequence_id == 0 {
            return Err(SlingshotTransportError::MissingSequenceId);
        }
        Ok(())
    }
}

fn require_environment_id(env: &RemoteControlEnvelope) -> Result<(), SlingshotTransportError> {
    if env.environment_id.as_deref().is_none_or(str::is_empty) {
        return Err(SlingshotTransportError::MissingEnvironmentId);
    }
    Ok(())
}

fn require_stream_id(env: &RemoteControlEnvelope) -> Result<(), SlingshotTransportError> {
    if env.stream_id.as_deref().is_none_or(str::is_empty) {
        return Err(SlingshotTransportError::MissingStreamId);
    }
    Ok(())
}

fn forbid_message(env: &RemoteControlEnvelope) -> Result<(), SlingshotTransportError> {
    if env.message.is_some() {
        return Err(invalid_payload(env));
    }
    Ok(())
}

fn invalid_payload(env: &RemoteControlEnvelope) -> SlingshotTransportError {
    SlingshotTransportError::InvalidServerPayload(
        serde_json::to_value(env).unwrap_or(serde_json::Value::Null),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base(kind: EnvelopeType) -> RemoteControlEnvelope {
        RemoteControlEnvelope {
            kind,
            client_id: "client".to_string(),
            environment_id: None,
            sequence_id: 1,
            stream_id: None,
            skip_history: None,
            cursor: None,
            message: None,
            state: None,
            status: None,
        }
    }

    #[test]
    fn camel_case_roundtrip() {
        let env = RemoteControlEnvelope {
            kind: EnvelopeType::ClientMessage,
            client_id: "C1".into(),
            environment_id: Some("E1".into()),
            sequence_id: 7,
            stream_id: Some("S1".into()),
            skip_history: Some(true),
            cursor: None,
            message: Some(serde_json::json!({"jsonrpc": "2.0", "method": "initialized"})),
            state: None,
            status: None,
        };
        let value = serde_json::to_value(&env).unwrap();
        assert_eq!(value["type"], "clientMessage");
        assert_eq!(value["clientId"], "C1");
        assert_eq!(value["environmentId"], "E1");
        assert_eq!(value["sequenceId"], 7);
        assert_eq!(value["streamId"], "S1");
        assert_eq!(value["skipHistory"], true);
        let decoded: RemoteControlEnvelope = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, env);
    }

    #[test]
    fn validates_missing_server_message_stream_id() {
        let mut env = base(EnvelopeType::ServerMessage);
        env.environment_id = Some("E1".into());
        env.message = Some(serde_json::json!({"jsonrpc": "2.0", "method": "x"}));
        assert_eq!(
            env.validate_inbound(),
            Err(SlingshotTransportError::MissingStreamId)
        );
    }

    #[test]
    fn validates_client_message_must_be_object() {
        let mut env = base(EnvelopeType::ClientMessage);
        env.environment_id = Some("E1".into());
        env.stream_id = Some("S1".into());
        env.message = Some(serde_json::json!(["bad"]));
        assert_eq!(
            env.validate_outbound(),
            Err(SlingshotTransportError::InvalidClientPayload)
        );
    }

    #[test]
    fn rejects_skip_history_on_ping() {
        let mut env = base(EnvelopeType::Ping);
        env.skip_history = Some(true);
        assert!(matches!(
            env.validate_inbound(),
            Err(SlingshotTransportError::InvalidServerPayload(_))
        ));
    }
}
