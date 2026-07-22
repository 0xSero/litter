//! FFI layer for iOS and Android consumption.
//!
//! Uses UniFFI proc-macro approach for automatic Swift/Kotlin binding generation.
//! The scaffolding macro is invoked in lib.rs; this module holds additional
//! FFI helper types and exported functions.

pub(crate) mod alleycat;
mod android;
mod app_store;
mod client;
mod discovery;
mod errors;
mod parser;
mod reconnect;
mod remote_path;
pub(crate) mod shared;
mod ssh;
mod terminal;

pub use crate::local_studio::{
    LocalStudioAdvertisement, LocalStudioAgentRuntimeSection, LocalStudioAgentRuntimeStats,
    LocalStudioAttachmentAvailability, LocalStudioAttachmentDescriptor, LocalStudioBridgeError,
    LocalStudioCapabilitiesManifest, LocalStudioCapability, LocalStudioComponentState,
    LocalStudioContentHashAlgorithm, LocalStudioContentHashes, LocalStudioControllerActionKind,
    LocalStudioControllerHealth, LocalStudioControllerLoadResult, LocalStudioControllerSections,
    LocalStudioControllerSnapshot, LocalStudioControllerStatus, LocalStudioErrorCode,
    LocalStudioErrorDetails, LocalStudioErrorResult, LocalStudioExternalSessionIdentity,
    LocalStudioFreshness, LocalStudioGpuDevice, LocalStudioGpuSnapshot, LocalStudioGpusSection,
    LocalStudioHashReference, LocalStudioHealthSection, LocalStudioMessageDescriptor,
    LocalStudioMessagePart, LocalStudioMessageRole, LocalStudioMetrics, LocalStudioMetricsSection,
    LocalStudioSectionName, LocalStudioSessionAuthority, LocalStudioSessionDescriptor,
    LocalStudioSessionIdentityKind, LocalStudioSessionListCursor, LocalStudioSessionListCursorKind,
    LocalStudioSessionListPage, LocalStudioSessionListResult, LocalStudioSessionMetadata,
    LocalStudioSessionOrigin, LocalStudioSessionPage, LocalStudioSessionReadResult,
    LocalStudioSnapshotState, LocalStudioStatusSection, LocalStudioToolDescriptor,
    LocalStudioToolState, LocalStudioTransferCursor, LocalStudioTransferCursorKind,
};
pub use crate::ssh_bridge::{AgentAvailabilityStatus, RemoteAgentAvailability, SshBridgeTransport};
pub use alleycat::{
    AlleycatBridge, AppAlleycatAgentInfo, AppAlleycatAgentWire, AppAlleycatConnectResult,
    AppAlleycatPairPayload,
};
pub use app_store::{AppStore, AppStoreSubscription};
pub use client::AppClient;
pub use discovery::{
    AppSlingshotEnvironment, DiscoveryBridge, DiscoveryScanSubscription, ServerBridge,
};
pub use errors::ClientError;
pub use parser::MessageParser;
pub use reconnect::ReconnectController;
pub use remote_path::RemotePath;
pub use ssh::{AppSshBridgeConnectResult, AppSshConnectionResult, AppSshSessionResult, SshBridge};
pub use terminal::{
    TerminalBackendKind, TerminalCellMetrics, TerminalCellRange, TerminalConfig,
    TerminalCursorStyle, TerminalError, TerminalKeyAction, TerminalKeyCode, TerminalKeyEvent,
    TerminalKeyMods, TerminalOutputListener, TerminalPalette, TerminalRenderer,
    TerminalRendererBackend, TerminalSession, TerminalSize, TerminalThemePreset,
};

// Re-export reconnect boundary types so UniFFI can discover them.
pub use crate::reconnect::{
    ReconnectResult, SavedServerRecord, SlingshotCredentialProvider, SlingshotCredentialRecord,
    SshAuthMethodRecord, SshCredentialProvider, SshCredentialRecord,
};
