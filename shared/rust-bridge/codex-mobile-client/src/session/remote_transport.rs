//! Transport-agnostic reconnect surface for remote `AppServerClient`s.
//!
//! Both the SSH (russh + WebSocket-over-tunnel) and Alleycat (Iroh QUIC)
//! transports need to be able to re-establish their underlying connection
//! and produce a fresh `AppServerClient` after a transient drop. This module
//! defines the small trait the session worker uses to drive that operation
//! without knowing which transport is underneath.

use std::sync::Arc;

use async_trait::async_trait;
use codex_app_server_client::{AppServerClient, RemoteAppServerConnectArgs};

use crate::transport::TransportError;

/// Transport-scoped state that must outlive the worker's `client` binding
/// (e.g. the iroh `Connection` backing an Alleycat stream). The worker
/// swaps the keepalive Arc on each successful reconnect so the previous
/// resource is dropped only AFTER the new one is installed.
///
/// The `close()` hook is called once before the worker drops the
/// keepalive on graceful teardown (`SessionCommand::Shutdown` or
/// `disconnect()`), so transports can issue a typed close frame to the
/// peer. Default impl is a no-op for transports (e.g. SSH) where the
/// underlying TCP stream is closed by `AppServerClient::shutdown`.
pub(crate) trait SessionKeepalive: Send + Sync + 'static {
    /// Send a graceful close to the peer. May be called concurrently with
    /// the worker's own teardown — implementations must be idempotent and
    /// non-panicking.
    fn close(&self) {}
}

/// Result of a successful reconnect.
pub(crate) struct Reconnected {
    /// Fresh client wired to the newly-established transport.
    pub client: AppServerClient,
    /// Optional transport-scoped resource (see [`SessionKeepalive`]). The
    /// worker keeps the previous keepalive alive until the new client is
    /// installed; on graceful shutdown it calls `close()` before dropping.
    pub keepalive: Option<Arc<dyn SessionKeepalive>>,
}

pub(crate) fn replace_keepalive_if_present(
    current: &mut Option<Arc<dyn SessionKeepalive>>,
    next: Option<Arc<dyn SessionKeepalive>>,
) {
    if next.is_some() {
        *current = next;
    }
}

/// Reconnect strategy for a remote `AppServerClient`.
///
/// Implementations are held by the session worker as `Arc<dyn RemoteTransport>`.
/// Reconnect runs only when the existing client drops (cold path), so dynamic
/// dispatch overhead is irrelevant compared to the network handshake cost.
#[async_trait]
pub(crate) trait RemoteTransport: Send + Sync + 'static {
    /// Re-establish the underlying transport and return a fresh client.
    ///
    /// `args` and `websocket_url` describe the original connect parameters and
    /// are provided for transports that fall back to a plain WebSocket connect
    /// (e.g. SSH after a port-forward refresh). Transports that ignore them
    /// (e.g. Alleycat, which derives everything from its own params) may do so.
    async fn reconnect(
        &self,
        args: &RemoteAppServerConnectArgs,
        websocket_url: &str,
    ) -> Result<Reconnected, TransportError>;

    /// Hint that the host network may have changed (e.g. iOS resumed the
    /// app from background suspension). Transports that have an iroh
    /// `Endpoint` use this to call `Endpoint::network_change()` so QUIC
    /// can re-probe paths and refresh relay connections without waiting
    /// for the idle timeout. Default: no-op for TCP-based transports
    /// where the OS already surfaces network changes.
    async fn notify_network_change(&self) {}

    /// Tear down the currently-installed underlying connection — used
    /// when the application has out-of-band knowledge that the connection
    /// is dead even though iroh hasn't observed it yet (e.g. the OS
    /// suspended us for longer than iroh's per-path idle timeout). For
    /// alleycat this calls `Connection::close()` on the live session;
    /// the worker's `client.next_event()` then yields `None` and the
    /// existing reconnect path opens a fresh `Connection` on the shared
    /// `Endpoint`. Default: no-op for transports where the OS has
    /// already surfaced any genuinely-dead state via the underlying
    /// stream's read/write errors.
    async fn close_current_connection(&self) {}
}

#[cfg(test)]
mod tests {
    //! Tests for the `RemoteTransport` contract surface.
    //!
    //! Exercising `reconnect_remote_client` end-to-end requires constructing a
    //! real `AppServerClient`, which has no public test constructor. So these
    //! tests cover the parts that are testable in isolation: drop ordering of
    //! the keepalive slot the worker maintains, and the trait being usable as
    //! `Arc<dyn RemoteTransport>`.

    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct DropCounter {
        counter: Arc<AtomicUsize>,
    }

    impl Drop for DropCounter {
        fn drop(&mut self) {
            self.counter.fetch_add(1, Ordering::SeqCst);
        }
    }

    impl SessionKeepalive for DropCounter {}

    /// The worker maintains `let mut keepalive: Option<Arc<dyn SessionKeepalive>>`
    /// and on a successful reconnect runs `*keepalive = next.keepalive`.
    /// Verify that assigning a new `Some(...)` drops the previous Arc, and
    /// that holding `None` leaves the previous Arc untouched.
    #[test]
    fn keepalive_assignment_drops_previous_arc() {
        let drop_count = Arc::new(AtomicUsize::new(0));
        let initial: Arc<dyn SessionKeepalive> = Arc::new(DropCounter {
            counter: Arc::clone(&drop_count),
        });
        let mut keepalive: Option<Arc<dyn SessionKeepalive>> = Some(Arc::clone(&initial));

        // Drop the local strong reference; only `keepalive` keeps it alive now.
        drop(initial);
        assert_eq!(drop_count.load(Ordering::SeqCst), 0);

        // SSH-style reconnect: keepalive is None, slot must NOT be cleared.
        let next_ssh: Option<Arc<dyn SessionKeepalive>> = None;
        replace_keepalive_if_present(&mut keepalive, next_ssh);
        assert_eq!(
            drop_count.load(Ordering::SeqCst),
            0,
            "an SSH reconnect (keepalive: None) must not clobber the existing keepalive"
        );

        // Alleycat-style reconnect: keepalive carries a fresh Arc; old one drops.
        let next_alleycat_drop_count = Arc::new(AtomicUsize::new(0));
        let next_alleycat: Arc<dyn SessionKeepalive> = Arc::new(DropCounter {
            counter: Arc::clone(&next_alleycat_drop_count),
        });
        replace_keepalive_if_present(&mut keepalive, Some(next_alleycat));
        assert_eq!(
            drop_count.load(Ordering::SeqCst),
            1,
            "the previous keepalive Arc must drop exactly once after the swap"
        );
        assert_eq!(
            next_alleycat_drop_count.load(Ordering::SeqCst),
            0,
            "the new keepalive Arc must remain alive"
        );

        // Worker exit: dropping the slot drops the new keepalive.
        drop(keepalive);
        assert_eq!(next_alleycat_drop_count.load(Ordering::SeqCst), 1);
    }

    /// `RemoteTransport` must be usable as a trait object (`Arc<dyn ...>`).
    /// This compiles iff the trait stays object-safe.
    #[test]
    fn trait_is_object_safe() {
        struct FakeTransport;

        #[async_trait]
        impl RemoteTransport for FakeTransport {
            async fn reconnect(
                &self,
                _args: &RemoteAppServerConnectArgs,
                _websocket_url: &str,
            ) -> Result<Reconnected, TransportError> {
                Err(TransportError::ConnectionFailed("test".into()))
            }
        }

        let _t: Arc<dyn RemoteTransport> = Arc::new(FakeTransport);
    }
}
