//! Typed consumer contract for Local Studio's `litter-bridge/v1` realtime API.
//!
//! This module mirrors contract version 1 merged by Local Studio PR #347
//! (`f465e88b`) and its language-neutral golden fixture. It deliberately
//! contains no transport, broker, WebRTC, or lifecycle policy. Decoding these
//! types must not be treated as proof that `realtime.session` is advertised or
//! usable.

use std::collections::HashSet;
use std::fmt;
use std::hash::Hash;
use std::sync::OnceLock;

use regex::Regex;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

pub const LITTER_BRIDGE_PROTOCOL_VERSION: u8 = 1;
pub const LITTER_BRIDGE_REALTIME_CONTRACT_VERSION: u8 = 1;
pub const LOCAL_STUDIO_REALTIME_GOLDEN_SHA256: &str =
    "271249e2a7dc3c8cba855eec0fd9ab28e30a75733c1375970114157ce318da73";
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

fn wire_len(value: &str) -> usize {
    // Effect/JavaScript length predicates count UTF-16 code units.
    value.encode_utf16().count()
}

fn validate_identifier(value: &str) -> Result<(), &'static str> {
    if value.is_empty() {
        return Err("identifier must not be empty");
    }
    if value.trim() != value {
        return Err("identifier must be trimmed");
    }
    if wire_len(value) > 512 {
        return Err("identifier exceeds 512 characters");
    }
    Ok(())
}

fn validate_short_text(value: &str) -> Result<(), &'static str> {
    if wire_len(value) > 4_096 {
        return Err("text exceeds 4096 characters");
    }
    Ok(())
}

fn validate_wire_text(value: &str) -> Result<(), &'static str> {
    if wire_len(value) > 4_000_000 {
        return Err("wire text exceeds 4000000 characters");
    }
    Ok(())
}

fn validate_opaque_token(value: &str) -> Result<(), &'static str> {
    if value.is_empty() {
        return Err("opaque token must not be empty");
    }
    if value.trim() != value {
        return Err("opaque token must be trimmed");
    }
    if wire_len(value) > 2_048 {
        return Err("opaque token exceeds 2048 characters");
    }
    Ok(())
}

fn timestamp_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$")
            .expect("timestamp pattern is valid")
    })
}

fn validate_timestamp(value: &str) -> Result<(), &'static str> {
    if timestamp_pattern().is_match(value) {
        Ok(())
    } else {
        Err("timestamp must use the litter-bridge UTC wire format")
    }
}

fn nonce_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r"^[A-Za-z0-9_-]+$").expect("nonce pattern is valid"))
}

fn validate_nonce(value: &str) -> Result<(), &'static str> {
    if value.trim() != value {
        return Err("nonce must be trimmed");
    }
    if !(16..=512).contains(&wire_len(value)) {
        return Err("nonce must contain 16 to 512 characters");
    }
    if !nonce_pattern().is_match(value) {
        return Err("nonce contains unsupported characters");
    }
    Ok(())
}

fn validate_signature(value: &str) -> Result<(), &'static str> {
    if value.trim() != value {
        return Err("signature must be trimmed");
    }
    if !(43..=512).contains(&wire_len(value)) {
        return Err("signature must contain 43 to 512 characters");
    }
    if !nonce_pattern().is_match(value) {
        return Err("signature contains unsupported characters");
    }
    Ok(())
}

fn validate_sha256(value: &str) -> Result<(), &'static str> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err("SHA-256 value must be 64 lowercase hexadecimal characters")
    }
}

macro_rules! validated_string {
    ($name:ident, $validate:ident) => {
        #[derive(Clone, PartialEq, Eq, Hash)]
        pub struct $name(String);

        impl $name {
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                $validate(&value).map_err(D::Error::custom)?;
                Ok(Self(value))
            }
        }
    };
}

macro_rules! sensitive_string {
    ($name:ident, $validate:ident) => {
        #[derive(Clone, PartialEq, Eq)]
        pub struct $name(String);

        impl $name {
            /// Deliberate access for transport code. Never log the returned value.
            pub fn expose_secret(&self) -> &str {
                &self.0
            }

            pub fn len_bytes(&self) -> usize {
                self.0.len()
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("<redacted>")
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                $validate(&value).map_err(D::Error::custom)?;
                Ok(Self(value))
            }
        }
    };
}

validated_string!(Identifier, validate_identifier);
validated_string!(ShortText, validate_short_text);
validated_string!(Timestamp, validate_timestamp);
validated_string!(Nonce, validate_nonce);
validated_string!(Sha256, validate_sha256);
sensitive_string!(Signature, validate_signature);
sensitive_string!(OpaqueToken, validate_opaque_token);
sensitive_string!(SensitiveWireText, validate_wire_text);
sensitive_string!(SensitiveShortText, validate_short_text);

macro_rules! exact_integer {
    ($name:ident, $expected:expr, $description:literal) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub struct $name;

        impl $name {
            pub const fn value(self) -> u8 {
                $expected
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_u8($expected)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                let value = deserialize_safe_non_negative_integer(deserializer)?;
                if value == u64::from($expected) {
                    Ok(Self)
                } else {
                    Err(D::Error::custom(concat!("unsupported ", $description)))
                }
            }
        }
    };
}

exact_integer!(
    ProtocolVersion,
    LITTER_BRIDGE_PROTOCOL_VERSION,
    "protocol version"
);

fn deserialize_safe_non_negative_integer<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    struct SafeIntegerVisitor;

    impl<'de> serde::de::Visitor<'de> for SafeIntegerVisitor {
        type Value = u64;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("a non-negative JSON safe integer")
        }

        fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            if value <= MAX_SAFE_INTEGER {
                Ok(value)
            } else {
                Err(E::custom("integer exceeds the JSON safe integer range"))
            }
        }

        fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            if value < 0 {
                return Err(E::custom("integer must be non-negative"));
            }
            self.visit_u64(value as u64)
        }

        fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            if !value.is_finite()
                || value < 0.0
                || value.fract() != 0.0
                || value > MAX_SAFE_INTEGER as f64
            {
                return Err(E::custom("number must be a non-negative JSON safe integer"));
            }
            Ok(value as u64)
        }
    }

    deserializer.deserialize_any(SafeIntegerVisitor)
}
exact_integer!(
    RealtimeContractVersion,
    LITTER_BRIDGE_REALTIME_CONTRACT_VERSION,
    "realtime contract version"
);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct NonNegativeInteger(u64);

impl NonNegativeInteger {
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl Serialize for NonNegativeInteger {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u64(self.0)
    }
}

impl<'de> Deserialize<'de> for NonNegativeInteger {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = deserialize_safe_non_negative_integer(deserializer)?;
        Ok(Self(value))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct PositiveInteger(u64);

impl PositiveInteger {
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl Serialize for PositiveInteger {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u64(self.0)
    }
}

impl<'de> Deserialize<'de> for PositiveInteger {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = deserialize_safe_non_negative_integer(deserializer)?;
        if value == 0 {
            return Err(D::Error::custom("integer must be positive"));
        }
        Ok(Self(value))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NonNegativeNumber(NonNegativeNumberRepr);

#[derive(Clone, Copy, Debug, PartialEq)]
enum NonNegativeNumberRepr {
    Integer(u64),
    Float(f64),
}

impl NonNegativeNumber {
    pub const fn get(self) -> f64 {
        match self.0 {
            NonNegativeNumberRepr::Integer(value) => value as f64,
            NonNegativeNumberRepr::Float(value) => value,
        }
    }
}

impl Serialize for NonNegativeNumber {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self.0 {
            NonNegativeNumberRepr::Integer(value) => serializer.serialize_u64(value),
            NonNegativeNumberRepr::Float(value) => serializer.serialize_f64(value),
        }
    }
}

impl<'de> Deserialize<'de> for NonNegativeNumber {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct NonNegativeNumberVisitor;

        impl<'de> serde::de::Visitor<'de> for NonNegativeNumberVisitor {
            type Value = NonNegativeNumber;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a finite non-negative number")
            }

            fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(NonNegativeNumber(NonNegativeNumberRepr::Integer(value)))
            }

            fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if value < 0 {
                    return Err(E::custom("number must be finite and non-negative"));
                }
                Ok(NonNegativeNumber(NonNegativeNumberRepr::Integer(
                    value as u64,
                )))
            }

            fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if !value.is_finite() || value < 0.0 {
                    return Err(E::custom("number must be finite and non-negative"));
                }
                Ok(NonNegativeNumber(NonNegativeNumberRepr::Float(value)))
            }
        }

        deserializer.deserialize_any(NonNegativeNumberVisitor)
    }
}

fn deserialize_nullable<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

fn deserialize_unique<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Eq + Hash + Clone,
{
    let values = Vec::<T>::deserialize(deserializer)?;
    let mut seen = HashSet::with_capacity(values.len());
    if values.iter().any(|value| !seen.insert(value.clone())) {
        return Err(D::Error::custom("array values must be unique"));
    }
    Ok(values)
}

fn deserialize_non_empty_unique<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Eq + Hash + Clone,
{
    let values = deserialize_unique(deserializer)?;
    if values.is_empty() {
        return Err(D::Error::custom("array must not be empty"));
    }
    Ok(values)
}

macro_rules! exact_string {
    ($name:ident, $expected:literal) => {
        #[derive(Clone, Copy, PartialEq, Eq)]
        struct $name;

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str($expected)
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_str($expected)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                if value == $expected {
                    Ok(Self)
                } else {
                    Err(D::Error::custom(concat!("expected literal ", $expected)))
                }
            }
        }
    };
}

exact_string!(Ed25519Algorithm, "ed25519");
exact_string!(RealtimeSessionCapability, "realtime.session");
exact_string!(WebRtcOfferType, "webrtc_offer");
exact_string!(WebRtcAnswerType, "webrtc_answer");

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RealtimeProvider {
    #[serde(rename = "provider_native")]
    ProviderNative,
    #[serde(rename = "local_pipeline")]
    LocalPipeline,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RealtimeModality {
    #[serde(rename = "audio")]
    Audio,
    #[serde(rename = "text")]
    Text,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RealtimeSignaling {
    #[serde(rename = "webrtc_offer_answer")]
    WebRtcOfferAnswer,
    #[serde(rename = "local_websocket")]
    LocalWebSocket,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RealtimeSessionState {
    #[serde(rename = "creating")]
    Creating,
    #[serde(rename = "negotiating")]
    Negotiating,
    #[serde(rename = "active")]
    Active,
    #[serde(rename = "reconnecting")]
    Reconnecting,
    #[serde(rename = "closing")]
    Closing,
    #[serde(rename = "closed")]
    Closed,
    #[serde(rename = "expired")]
    Expired,
    #[serde(rename = "failed")]
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RealtimeUnavailableReason {
    #[serde(rename = "provider_not_configured")]
    ProviderNotConfigured,
    #[serde(rename = "model_not_loaded")]
    ModelNotLoaded,
    #[serde(rename = "model_unsupported")]
    ModelUnsupported,
    #[serde(rename = "speech_plugin_unavailable")]
    SpeechPluginUnavailable,
    #[serde(rename = "runtime_unavailable")]
    RuntimeUnavailable,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RealtimeVoice {
    pub id: Identifier,
    pub label: Identifier,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeCapability {
    pub capability_id: Identifier,
    pub provider: RealtimeProvider,
    pub model_id: Identifier,
    pub available: bool,
    pub unavailable_reason: Option<RealtimeUnavailableReason>,
    pub input_modalities: Vec<RealtimeModality>,
    pub output_modalities: Vec<RealtimeModality>,
    pub signaling: RealtimeSignaling,
    pub voices: Vec<RealtimeVoice>,
    pub supports_reconnect: bool,
    pub supports_update: bool,
    pub session_ttl_seconds: PositiveInteger,
    pub max_signal_bytes: PositiveInteger,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RealtimeCapabilityWire {
    capability_id: Identifier,
    provider: RealtimeProvider,
    model_id: Identifier,
    available: bool,
    #[serde(deserialize_with = "deserialize_nullable")]
    unavailable_reason: Option<RealtimeUnavailableReason>,
    #[serde(deserialize_with = "deserialize_unique")]
    input_modalities: Vec<RealtimeModality>,
    #[serde(deserialize_with = "deserialize_unique")]
    output_modalities: Vec<RealtimeModality>,
    signaling: RealtimeSignaling,
    voices: Vec<RealtimeVoice>,
    supports_reconnect: bool,
    supports_update: bool,
    session_ttl_seconds: PositiveInteger,
    max_signal_bytes: PositiveInteger,
}

impl<'de> Deserialize<'de> for RealtimeCapability {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = RealtimeCapabilityWire::deserialize(deserializer)?;
        if wire.available != wire.unavailable_reason.is_none() {
            return Err(D::Error::custom(
                "availability and unavailableReason must agree",
            ));
        }
        Ok(Self {
            capability_id: wire.capability_id,
            provider: wire.provider,
            model_id: wire.model_id,
            available: wire.available,
            unavailable_reason: wire.unavailable_reason,
            input_modalities: wire.input_modalities,
            output_modalities: wire.output_modalities,
            signaling: wire.signaling,
            voices: wire.voices,
            supports_reconnect: wire.supports_reconnect,
            supports_update: wire.supports_update,
            session_ttl_seconds: wire.session_ttl_seconds,
            max_signal_bytes: wire.max_signal_bytes,
        })
    }
}

impl RealtimeCapability {
    /// Enforces the provider-advertised ICE payload bound without applying any
    /// signaling or lifecycle policy.
    pub fn validate_signal(&self, signal: &RealtimeSignal) -> Result<(), ContractValidationError> {
        if signal.payload_len_bytes() as u64 > self.max_signal_bytes.get() {
            return Err(ContractValidationError::SignalTooLarge {
                actual_bytes: signal.payload_len_bytes() as u64,
                limit_bytes: self.max_signal_bytes.get(),
            });
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceAuth {
    pub device_id: Identifier,
    pub key_id: Identifier,
    algorithm: Ed25519Algorithm,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RealtimeReadAuth {
    pub device: DeviceAuth,
    pub request_id: Identifier,
    pub issued_at: Timestamp,
    pub expires_at: Timestamp,
    pub nonce: Nonce,
    pub body_hash: Sha256,
    pub signature: Signature,
    capability: RealtimeSessionCapability,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RealtimeMutationAuth {
    pub device: DeviceAuth,
    pub request_id: Identifier,
    pub issued_at: Timestamp,
    pub expires_at: Timestamp,
    pub nonce: Nonce,
    pub body_hash: Sha256,
    pub signature: Signature,
    capability: RealtimeSessionCapability,
    pub idempotency_key: Identifier,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RealtimeOffer {
    #[serde(rename = "type")]
    message_type: WebRtcOfferType,
    pub sdp: SensitiveWireText,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RealtimeAnswer {
    #[serde(rename = "type")]
    message_type: WebRtcAnswerType,
    pub sdp: SensitiveWireText,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RealtimeSession {
    pub session_id: Identifier,
    pub client_session_id: Identifier,
    pub capability_id: Identifier,
    pub device_id: Identifier,
    pub state: RealtimeSessionState,
    pub created_at: Timestamp,
    pub expires_at: Timestamp,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub reconnect_token: Option<OpaqueToken>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum RealtimeSignal {
    #[serde(rename = "ice_candidate")]
    IceCandidate {
        candidate: SensitiveWireText,
        #[serde(rename = "sdpMid", deserialize_with = "deserialize_nullable")]
        sdp_mid: Option<Identifier>,
        #[serde(rename = "sdpMLineIndex", deserialize_with = "deserialize_nullable")]
        sdp_m_line_index: Option<NonNegativeInteger>,
    },
    #[serde(rename = "ice_complete")]
    IceComplete,
}

impl RealtimeSignal {
    pub fn payload_len_bytes(&self) -> usize {
        match self {
            Self::IceCandidate { candidate, .. } => candidate.len_bytes(),
            Self::IceComplete => 0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RealtimeCloseReason {
    #[serde(rename = "user")]
    User,
    #[serde(rename = "handoff")]
    Handoff,
    #[serde(rename = "timeout")]
    Timeout,
    #[serde(rename = "shutdown")]
    Shutdown,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum RealtimeRequest {
    #[serde(rename = "realtime_capabilities_request")]
    Capabilities {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        auth: RealtimeReadAuth,
        #[serde(rename = "controllerId")]
        controller_id: Identifier,
        #[serde(
            rename = "acceptedContractVersions",
            deserialize_with = "deserialize_non_empty_unique"
        )]
        accepted_contract_versions: Vec<RealtimeContractVersion>,
    },
    #[serde(rename = "realtime_session_create_request")]
    CreateSession {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        auth: RealtimeMutationAuth,
        #[serde(rename = "controllerId")]
        controller_id: Identifier,
        #[serde(rename = "clientSessionId")]
        client_session_id: Identifier,
        #[serde(rename = "capabilityId")]
        capability_id: Identifier,
        #[serde(rename = "voiceId", deserialize_with = "deserialize_nullable")]
        voice_id: Option<Identifier>,
        offer: RealtimeOffer,
    },
    #[serde(rename = "realtime_signal_request")]
    Signal {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        auth: RealtimeMutationAuth,
        #[serde(rename = "sessionId")]
        session_id: Identifier,
        signal: RealtimeSignal,
    },
    #[serde(rename = "realtime_session_update_request")]
    UpdateSession {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        auth: RealtimeMutationAuth,
        #[serde(rename = "sessionId")]
        session_id: Identifier,
        #[serde(rename = "voiceId", deserialize_with = "deserialize_nullable")]
        voice_id: Option<Identifier>,
        #[serde(deserialize_with = "deserialize_nullable")]
        instructions: Option<SensitiveShortText>,
    },
    #[serde(rename = "realtime_session_close_request")]
    CloseSession {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        auth: RealtimeMutationAuth,
        #[serde(rename = "sessionId")]
        session_id: Identifier,
        reason: RealtimeCloseReason,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LitterBridgeErrorCode {
    #[serde(rename = "invalid_request")]
    InvalidRequest,
    #[serde(rename = "unauthorized")]
    Unauthorized,
    #[serde(rename = "forbidden")]
    Forbidden,
    #[serde(rename = "expired_request")]
    ExpiredRequest,
    #[serde(rename = "replay_detected")]
    ReplayDetected,
    #[serde(rename = "unsupported_version")]
    UnsupportedVersion,
    #[serde(rename = "capability_denied")]
    CapabilityDenied,
    #[serde(rename = "not_found")]
    NotFound,
    #[serde(rename = "revision_conflict")]
    RevisionConflict,
    #[serde(rename = "rate_limited")]
    RateLimited,
    #[serde(rename = "payload_too_large")]
    PayloadTooLarge,
    #[serde(rename = "integrity_failed")]
    IntegrityFailed,
    #[serde(rename = "controller_unavailable")]
    ControllerUnavailable,
    #[serde(rename = "section_unavailable")]
    SectionUnavailable,
    #[serde(rename = "agent_runtime_unavailable")]
    AgentRuntimeUnavailable,
    #[serde(rename = "realtime_unavailable")]
    RealtimeUnavailable,
    #[serde(rename = "realtime_session_expired")]
    RealtimeSessionExpired,
    #[serde(rename = "realtime_state_conflict")]
    RealtimeStateConflict,
    #[serde(rename = "internal")]
    Internal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LitterBridgeSectionName {
    #[serde(rename = "health")]
    Health,
    #[serde(rename = "status")]
    Status,
    #[serde(rename = "gpus")]
    Gpus,
    #[serde(rename = "metrics")]
    Metrics,
    #[serde(rename = "agent-runtime")]
    AgentRuntime,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LitterBridgeErrorDetails {
    #[serde(deserialize_with = "deserialize_nullable")]
    pub field: Option<Identifier>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub section: Option<LitterBridgeSectionName>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub expected_revision: Option<NonNegativeInteger>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub current_revision: Option<NonNegativeInteger>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub retry_after_ms: Option<NonNegativeInteger>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub limit_bytes: Option<NonNegativeInteger>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LitterBridgeError {
    pub code: LitterBridgeErrorCode,
    pub message: ShortText,
    pub retriable: bool,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub request_id: Option<Identifier>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub details: Option<LitterBridgeErrorDetails>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum RealtimeResult {
    #[serde(rename = "realtime_capabilities")]
    Capabilities {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        #[serde(rename = "requestId")]
        request_id: Identifier,
        #[serde(rename = "controllerId")]
        controller_id: Identifier,
        #[serde(rename = "generatedAt")]
        generated_at: Timestamp,
        capabilities: Vec<RealtimeCapability>,
    },
    #[serde(rename = "realtime_session_created")]
    SessionCreated {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        #[serde(rename = "requestId")]
        request_id: Identifier,
        #[serde(rename = "idempotencyKey")]
        idempotency_key: Identifier,
        session: RealtimeSession,
        answer: RealtimeAnswer,
        #[serde(rename = "brokerLatencyMs")]
        broker_latency_ms: NonNegativeNumber,
    },
    #[serde(rename = "realtime_session_status")]
    SessionStatus {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        #[serde(rename = "eventId")]
        event_id: Identifier,
        sequence: NonNegativeInteger,
        #[serde(rename = "observedAt")]
        observed_at: Timestamp,
        session: RealtimeSession,
        #[serde(rename = "brokerLatencyMs", deserialize_with = "deserialize_nullable")]
        broker_latency_ms: Option<NonNegativeNumber>,
        #[serde(
            rename = "mediaConnectionLatencyMs",
            deserialize_with = "deserialize_nullable"
        )]
        media_connection_latency_ms: Option<NonNegativeNumber>,
        #[serde(deserialize_with = "deserialize_nullable")]
        error: Option<LitterBridgeError>,
    },
    #[serde(rename = "realtime_mutation_ack")]
    MutationAck {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "contractVersion")]
        contract_version: RealtimeContractVersion,
        #[serde(rename = "requestId")]
        request_id: Identifier,
        #[serde(rename = "idempotencyKey")]
        idempotency_key: Identifier,
        session: RealtimeSession,
    },
    #[serde(rename = "error")]
    Error {
        #[serde(rename = "protocolVersion")]
        protocol_version: ProtocolVersion,
        #[serde(rename = "requestId")]
        request_id: Identifier,
        error: LitterBridgeError,
    },
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ContractValidationError {
    #[error("signal payload is {actual_bytes} bytes; advertised limit is {limit_bytes} bytes")]
    SignalTooLarge { actual_bytes: u64, limit_bytes: u64 },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const GOLDEN_FIXTURE: &str =
        include_str!("../tests/fixtures/local-studio-litter-bridge-realtime-v1.json");

    #[derive(Debug, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct RealtimeV1Fixture {
        contract_version: RealtimeContractVersion,
        capabilities_request: RealtimeRequest,
        capabilities_result: RealtimeResult,
        create_request: RealtimeRequest,
        create_result: RealtimeResult,
        signal_request: RealtimeRequest,
        update_request: RealtimeRequest,
        close_request: RealtimeRequest,
        status: RealtimeResult,
    }

    #[test]
    fn local_studio_golden_fixture_conforms_and_round_trips() {
        let expected: Value = serde_json::from_str(GOLDEN_FIXTURE).expect("fixture is JSON");
        let fixture: RealtimeV1Fixture =
            serde_json::from_value(expected.clone()).expect("fixture conforms to Rust contract");
        let actual = serde_json::to_value(&fixture).expect("typed fixture serializes");

        assert_eq!(actual, expected);
        assert!(matches!(
            fixture.capabilities_request,
            RealtimeRequest::Capabilities { .. }
        ));
        assert!(matches!(
            fixture.capabilities_result,
            RealtimeResult::Capabilities { .. }
        ));
        assert!(matches!(
            fixture.create_request,
            RealtimeRequest::CreateSession { .. }
        ));
        assert!(matches!(
            fixture.create_result,
            RealtimeResult::SessionCreated { .. }
        ));
        assert!(matches!(
            fixture.signal_request,
            RealtimeRequest::Signal { .. }
        ));
        assert!(matches!(
            fixture.update_request,
            RealtimeRequest::UpdateSession { .. }
        ));
        assert!(matches!(
            fixture.close_request,
            RealtimeRequest::CloseSession { .. }
        ));
        assert!(matches!(
            fixture.status,
            RealtimeResult::SessionStatus { .. }
        ));
    }

    #[test]
    fn strict_decoding_rejects_unknown_fields_and_provider_credentials() {
        let mut fixture: Value = serde_json::from_str(GOLDEN_FIXTURE).unwrap();
        fixture["capabilitiesResult"]["capabilities"][0]["providerApiKey"] =
            Value::String("must-not-cross-the-bridge".into());

        let error = serde_json::from_value::<RealtimeV1Fixture>(fixture).unwrap_err();

        assert!(error.to_string().contains("unknown field"));
        assert!(!error.to_string().contains("must-not-cross-the-bridge"));
    }

    #[test]
    fn required_nullable_fields_cannot_be_omitted() {
        let mut fixture: Value = serde_json::from_str(GOLDEN_FIXTURE).unwrap();
        fixture["createRequest"]
            .as_object_mut()
            .unwrap()
            .remove("voiceId");

        let error = serde_json::from_value::<RealtimeV1Fixture>(fixture).unwrap_err();

        assert!(error.to_string().contains("voiceId"));
    }

    #[test]
    fn availability_and_reason_must_agree() {
        let mut capability = json!({
            "capabilityId": "provider-model",
            "provider": "provider_native",
            "modelId": "model",
            "available": false,
            "unavailableReason": null,
            "inputModalities": ["audio"],
            "outputModalities": ["audio"],
            "signaling": "webrtc_offer_answer",
            "voices": [],
            "supportsReconnect": false,
            "supportsUpdate": false,
            "sessionTtlSeconds": 60,
            "maxSignalBytes": 1024
        });

        let error = serde_json::from_value::<RealtimeCapability>(capability.clone()).unwrap_err();
        assert!(error.to_string().contains("availability"));

        capability["unavailableReason"] = Value::String("runtime_unavailable".into());
        serde_json::from_value::<RealtimeCapability>(capability).unwrap();
    }

    #[test]
    fn versions_and_unique_arrays_fail_closed() {
        let mut fixture: Value = serde_json::from_str(GOLDEN_FIXTURE).unwrap();
        fixture["contractVersion"] = json!(2);
        assert!(serde_json::from_value::<RealtimeV1Fixture>(fixture).is_err());

        let mut fixture: Value = serde_json::from_str(GOLDEN_FIXTURE).unwrap();
        fixture["capabilitiesRequest"]["acceptedContractVersions"] = json!([1, 1]);
        assert!(serde_json::from_value::<RealtimeV1Fixture>(fixture).is_err());

        let mut fixture: Value = serde_json::from_str(GOLDEN_FIXTURE).unwrap();
        fixture["capabilitiesResult"]["capabilities"][0]["inputModalities"] =
            json!(["audio", "audio"]);
        assert!(serde_json::from_value::<RealtimeV1Fixture>(fixture).is_err());
    }

    #[test]
    fn sensitive_values_are_redacted_from_debug_output() {
        let fixture: RealtimeV1Fixture = serde_json::from_str(GOLDEN_FIXTURE).unwrap();
        let debug = format!("{fixture:?}");

        for secret in [
            "fake-reconnect-token-1",
            "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n",
            "v=0\r\no=- 2 2 IN IP4 127.0.0.1\r\n",
            "candidate:1 1 UDP 2122260223 192.0.2.1 54321 typ host",
            "Answer concisely.",
            "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss",
        ] {
            assert!(
                !debug.contains(secret),
                "debug output leaked sensitive data"
            );
        }
        assert!(debug.contains("<redacted>"));
    }

    #[test]
    fn capability_enforces_its_advertised_signal_bound() {
        let capability: RealtimeCapability = serde_json::from_value(json!({
            "capabilityId": "provider-model",
            "provider": "provider_native",
            "modelId": "model",
            "available": true,
            "unavailableReason": null,
            "inputModalities": ["audio"],
            "outputModalities": ["audio"],
            "signaling": "webrtc_offer_answer",
            "voices": [],
            "supportsReconnect": false,
            "supportsUpdate": false,
            "sessionTtlSeconds": 60,
            "maxSignalBytes": 3
        }))
        .unwrap();
        let signal: RealtimeSignal = serde_json::from_value(json!({
            "type": "ice_candidate",
            "candidate": "four",
            "sdpMid": null,
            "sdpMLineIndex": null
        }))
        .unwrap();

        assert_eq!(
            capability.validate_signal(&signal),
            Err(ContractValidationError::SignalTooLarge {
                actual_bytes: 4,
                limit_bytes: 3,
            })
        );
    }

    #[test]
    fn error_envelope_is_typed_strict_and_safe() {
        let result: RealtimeResult = serde_json::from_value(json!({
            "type": "error",
            "protocolVersion": 1,
            "requestId": "request-error-1",
            "error": {
                "code": "realtime_state_conflict",
                "message": "Session is already closed",
                "retriable": false,
                "requestId": "request-error-1",
                "details": {
                    "field": null,
                    "section": null,
                    "expectedRevision": null,
                    "currentRevision": null,
                    "retryAfterMs": null,
                    "limitBytes": null
                }
            }
        }))
        .unwrap();

        assert!(matches!(
            result,
            RealtimeResult::Error {
                error: LitterBridgeError {
                    code: LitterBridgeErrorCode::RealtimeStateConflict,
                    ..
                },
                ..
            }
        ));
    }
}
