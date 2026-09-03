//! Public mobile boundary types.
//!
//! Hand-maintained types in `enums`, `models`, and `server_requests` are the
//! mobile-owned boundary.

pub mod enums;
pub mod models;
pub mod server_requests;
pub mod voice;
pub use enums::*;
pub use models::*;
pub use server_requests::*;
pub use voice::*;

/// Resolve the runtime kinds a thread-list request should fan out to: the
/// requested set (intersected with what the server session exposes) or, when
/// none is requested, every available runtime kind.
pub(crate) fn list_runtime_kinds(
    requested: Option<Vec<AgentRuntimeKind>>,
    available: &[AgentRuntimeKind],
) -> Vec<AgentRuntimeKind> {
    let mut runtimes = match requested {
        Some(requested) if !requested.is_empty() => requested
            .into_iter()
            .filter(|kind| available.contains(kind))
            .collect(),
        _ => available.to_vec(),
    };
    runtimes.sort();
    runtimes.dedup();
    runtimes
}
