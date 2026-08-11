//! Persistent SSH host-key fingerprint trust store.
//!
//! Storage itself is platform-owned (iOS Keychain / Android EncryptedSharedPreferences).
//! Rust owns the policy and the lookup-during-connect; platforms implement
//! [`TerminalSshTrustBackend`] to read/write the encrypted store.
//!
//! Wired into [`crate::terminal::ssh::open`]: before establishing the SSH
//! handshake, the terminal backend consults the trust store. The russh
//! host-key callback accepts a key only when:
//!
//! - a pin exists and the remote fingerprint matches it, OR
//! - no pin exists *and* `accept_unknown_host` is true.
//!
//! When the callback rejects, we map the resulting
//! [`crate::ssh::SshError::HostKeyVerification`] to a typed
//! [`crate::terminal::session::TerminalError::Backend`] detail string the
//! platform UI can parse:
//!
//! - `host-key-changed:<host>:<new_fingerprint>` — pin exists but differs.
//!   Platforms surface this as a refused connect with a fingerprint diff.
//! - `unknown-host:<fingerprint>` — no pin, `accept_unknown_host=false`.
//!   Platforms surface this as an "Accept this fingerprint?" sheet that
//!   then calls [`TerminalSshTrustStore::pin`] on user accept.

use std::sync::Arc;

/// Platform-implemented persistent storage for pinned host fingerprints.
///
/// iOS implements this on top of the Keychain; Android on top of
/// `androidx.security:security-crypto` EncryptedSharedPreferences. The
/// backend MUST be synchronous and side-effect free with respect to other
/// terminal operations — the trust store consults it on every connect.
#[uniffi::export(callback_interface)]
pub trait TerminalSshTrustBackend: Send + Sync {
    /// Look up the pinned SHA-256 fingerprint for `host:port`. Returns
    /// `None` if no pin is recorded.
    fn read(&self, host: String, port: u16) -> Option<String>;
    /// Persist `fingerprint` as the pin for `host:port`, overwriting any
    /// previously stored fingerprint.
    fn write(&self, host: String, port: u16, fingerprint: String);
    /// Remove any pin for `host:port`. Idempotent.
    fn remove(&self, host: String, port: u16);
}

/// UniFFI object wrapping a platform [`TerminalSshTrustBackend`].
///
/// Held by the terminal backend at session-open time. Cheap to construct;
/// the actual storage round-trip lives in the platform-supplied backend.
#[derive(uniffi::Object)]
pub struct TerminalSshTrustStore {
    backend: Arc<dyn TerminalSshTrustBackend>,
}

#[uniffi::export]
impl TerminalSshTrustStore {
    #[uniffi::constructor]
    pub fn new(backend: Box<dyn TerminalSshTrustBackend>) -> Self {
        Self {
            backend: Arc::from(backend),
        }
    }

    /// Return the pinned SHA-256 fingerprint for the given host/port, if any.
    pub fn pinned(&self, host: String, port: u16) -> Option<String> {
        let host = normalize_host(&host);
        self.backend.read(host, port)
    }

    /// Record `fingerprint` as the trusted pin for the given host/port.
    pub fn pin(&self, host: String, port: u16, fingerprint: String) {
        let host = normalize_host(&host);
        self.backend.write(host, port, fingerprint);
    }

    /// Remove any pin for the given host/port. Safe to call when no pin
    /// exists.
    pub fn unpin(&self, host: String, port: u16) {
        let host = normalize_host(&host);
        self.backend.remove(host, port);
    }
}

impl TerminalSshTrustStore {
    /// Internal accessor used by [`crate::terminal::ssh`] to read a pin
    /// without going through the UniFFI surface.
    pub(crate) fn lookup(&self, host: &str, port: u16) -> Option<String> {
        self.backend.read(normalize_host(host), port)
    }
}

/// Lowercase + strip bracket / scope-id noise so equality matches the way
/// `russh` normalizes the connect address.
pub(crate) fn normalize_host(host: &str) -> String {
    let mut value = host
        .trim()
        .trim_matches('[')
        .trim_matches(']')
        .to_string();
    value = value.replace("%25", "%");
    if !value.contains(':')
        && let Some(idx) = value.find('%') {
            value.truncate(idx);
        }
    value.to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct InMemoryBackend {
        store: Mutex<HashMap<(String, u16), String>>,
    }

    impl TerminalSshTrustBackend for InMemoryBackend {
        fn read(&self, host: String, port: u16) -> Option<String> {
            self.store.lock().unwrap().get(&(host, port)).cloned()
        }
        fn write(&self, host: String, port: u16, fingerprint: String) {
            self.store
                .lock()
                .unwrap()
                .insert((host, port), fingerprint);
        }
        fn remove(&self, host: String, port: u16) {
            self.store.lock().unwrap().remove(&(host, port));
        }
    }

    fn make_store() -> TerminalSshTrustStore {
        TerminalSshTrustStore::new(Box::new(InMemoryBackend::default()))
    }

    #[test]
    fn pin_then_lookup_returns_same_fingerprint() {
        let store = make_store();
        store.pin("example.com".into(), 22, "SHA256:abc".into());
        assert_eq!(
            store.pinned("example.com".into(), 22),
            Some("SHA256:abc".into())
        );
    }

    #[test]
    fn unpinned_host_returns_none() {
        let store = make_store();
        assert_eq!(store.pinned("missing.example".into(), 22), None);
    }

    #[test]
    fn unpin_clears_only_matching_entry() {
        let store = make_store();
        store.pin("example.com".into(), 22, "SHA256:abc".into());
        store.pin("other.example".into(), 22, "SHA256:def".into());
        store.unpin("example.com".into(), 22);
        assert_eq!(store.pinned("example.com".into(), 22), None);
        assert_eq!(
            store.pinned("other.example".into(), 22),
            Some("SHA256:def".into())
        );
    }

    #[test]
    fn pin_overwrites_previous_value() {
        let store = make_store();
        store.pin("example.com".into(), 22, "SHA256:abc".into());
        store.pin("example.com".into(), 22, "SHA256:xyz".into());
        assert_eq!(
            store.pinned("example.com".into(), 22),
            Some("SHA256:xyz".into())
        );
    }

    #[test]
    fn lookup_normalizes_host_casing_and_brackets() {
        let store = make_store();
        store.pin("Example.COM".into(), 22, "SHA256:abc".into());
        assert_eq!(
            store.pinned("[example.com]".into(), 22),
            Some("SHA256:abc".into())
        );
        assert_eq!(store.lookup("Example.COM", 22), Some("SHA256:abc".into()));
    }

    #[test]
    fn unpin_is_idempotent() {
        let store = make_store();
        store.unpin("nothing.example".into(), 22);
        store.unpin("nothing.example".into(), 22);
    }
}
