//! Shared terminal session surface.
//!
//! Platform renderers own libghostty/Metal/GL integration. This module owns the
//! backend lifecycle and raw PTY byte stream that Swift/Kotlin feed into their
//! renderer surfaces.

mod backend;
mod config;
mod input;
mod links;
mod local_ish;
mod local_proot;
mod osc;
mod remote_alleycat;
mod renderer;
mod selection;
mod session;
mod ssh;
mod ssh_known_hosts;

pub use config::{
    TerminalConfig, TerminalCursorStyle, TerminalPalette, TerminalThemePreset,
    render_ghostty_conf, theme_palette,
};
pub use input::{
    TerminalKeyAction, TerminalKeyCode, TerminalKeyEvent, TerminalKeyMods, encode_text,
    synthesize_special_key,
};
pub use links::{TerminalLink, TerminalLinkSource};
pub use osc::{
    TerminalCellPosition, TerminalHyperlink, TerminalPromptMark, TerminalSemanticState,
    TerminalSemanticStateListener,
};
pub use renderer::{
    TerminalBellListener, TerminalRenderer, TerminalRendererBackend, TerminalSendToAssistantPayload,
};
pub use selection::{TerminalCellMetrics, TerminalCellRange};
pub use session::{
    TerminalBackendKind, TerminalError, TerminalOutputListener, TerminalSession, TerminalSize,
};
pub use ssh::TerminalSshAuth;
pub use ssh_known_hosts::{TerminalSshTrustBackend, TerminalSshTrustStore};
pub(crate) use ssh_known_hosts::normalize_host;
