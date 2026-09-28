use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClientEnrollmentStartResponse {
    #[serde(alias = "client_id")]
    pub client_id: String,
    #[serde(alias = "account_user_id")]
    pub account_user_id: String,
    #[serde(alias = "device_key_challenge")]
    pub device_key_challenge: DeviceKeyChallenge,
}

pub type ClientEnrollmentResponse = ClientEnrollmentStartResponse;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceKeyChallenge {
    #[serde(rename = "type")]
    pub kind: String,
    pub nonce: String,
    pub purpose: String,
    pub audience: String,
    #[serde(alias = "challenge_id")]
    pub challenge_id: String,
    #[serde(alias = "target_origin")]
    pub target_origin: String,
    #[serde(alias = "target_path")]
    pub target_path: String,
    #[serde(alias = "account_user_id")]
    pub account_user_id: String,
    #[serde(alias = "client_id")]
    pub client_id: String,
    #[serde(alias = "challenge_token")]
    pub challenge_token: String,
    #[serde(alias = "device_identity_hash")]
    pub device_identity_hash: Option<String>,
    #[serde(alias = "challenge_expires_at")]
    pub challenge_expires_at: i64,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct ClientEnrollmentFinishRequest {
    pub client_id: String,
    pub step_up_token: String,
    pub device_identity: DeviceIdentity,
    pub device_key_proof: DeviceKeyProof,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct ClientRefreshStartRequest {
    pub client_id: String,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct ClientRefreshFinishRequest {
    pub client_id: String,
    pub device_key_proof: DeviceKeyProof,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct DeviceIdentity {
    pub key_id: String,
    pub public_key_spki_der_base64: String,
    pub algorithm: String,
    pub protection_class: String,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct DeviceKeyProof {
    pub challenge_token: String,
    pub key_id: String,
    pub signature_der_base64: String,
    pub signed_payload_base64: String,
    pub algorithm: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ClientEnrollmentTokenResponse {
    pub client_id: String,
    pub account_user_id: String,
    pub remote_control_token: String,
    pub expires_at: String,
    pub scopes: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceKeyConnectionChallenge {
    #[serde(rename = "type")]
    pub kind: String,
    pub nonce: String,
    pub audience: String,
    #[serde(alias = "session_id")]
    pub session_id: String,
    #[serde(alias = "target_origin")]
    pub target_origin: String,
    #[serde(alias = "target_path")]
    pub target_path: String,
    #[serde(alias = "account_user_id")]
    pub account_user_id: String,
    #[serde(alias = "client_id")]
    pub client_id: String,
    #[serde(alias = "token_sha256_base64url")]
    pub token_sha256_base64url: String,
    #[serde(alias = "token_expires_at")]
    pub token_expires_at: i64,
    pub scopes: Vec<String>,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceKeyConnectionProof {
    #[serde(rename = "type")]
    pub kind: String,
    pub key_id: String,
    pub signature_der_base64: String,
    pub signed_payload_base64: String,
    pub algorithm: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum EnvironmentKind {
    Single,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum KnownOperatingSystem {
    Macos,
    Windows,
    Linux,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(untagged)]
pub enum OperatingSystem {
    Known(KnownOperatingSystem),
    Unknown(String),
}

#[derive(Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlingshotEnvironment {
    #[serde(alias = "env_id")]
    pub id: String,
    pub kind: EnvironmentKind,
    #[serde(alias = "raw_display_name")]
    pub raw_display_name: Option<String>,
    pub name: Option<String>,
    #[serde(alias = "host_name")]
    pub host_name: Option<String>,
    pub online: bool,
    pub busy: bool,
    #[serde(alias = "os")]
    pub operating_system: OperatingSystem,
    #[serde(alias = "arch")]
    pub architecture: Option<String>,
    #[serde(alias = "app_server_version")]
    pub app_server_version: Option<String>,
    #[serde(alias = "last_seen_at")]
    pub last_seen_at: Option<DateTime<Utc>>,
}
