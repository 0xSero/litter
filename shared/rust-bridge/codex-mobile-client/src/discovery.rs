//! Server discovery: Bonjour/mDNS, Tailscale, LAN probing, ARP scanning.
//!
//! Multi-source progressive discovery with parallel candidate filtering,
//! reachability checking, and continuous monitoring.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures::future::join_all;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{Semaphore, broadcast, mpsc};
use tokio::task::JoinSet;

/// Default ports to probe for Codex and SSH servers.
const DEFAULT_SCAN_PORTS: &[u16] = &[8390, 9234, 22];

/// Maximum concurrent TCP probes during subnet scans.
const MAX_CONCURRENT_PROBES: usize = 64;

/// Interval between continuous scan sweeps.
const CONTINUOUS_SCAN_INTERVAL: Duration = Duration::from_secs(30);

/// Staleness threshold — servers not seen for this long are considered lost.
const SERVER_STALE_TIMEOUT: Duration = Duration::from_secs(90);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A server found during discovery.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredServer {
    pub id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub codex_port: Option<u16>,
    pub codex_ports: Vec<u16>,
    pub ssh_port: Option<u16>,
    pub source: DiscoverySource,
    pub metadata: HashMap<String, String>,
    #[serde(skip)]
    pub last_seen: Instant,
    pub reachable: bool,
}

/// A resolved mDNS/Bonjour service seed supplied by the platform layer.
#[derive(Debug, Clone)]
pub struct MdnsSeed {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub service_type: String,
    pub txt: HashMap<String, String>,
}

/// How the server was discovered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiscoverySource {
    Bonjour,
    Tailscale,
    LanProbe,
    ArpScan,
    Manual,
    Bundled,
}

/// Events emitted during continuous discovery.
#[derive(Debug, Clone)]
pub enum DiscoveryEvent {
    ServerFound(DiscoveredServer),
    ServerLost(String),
    ServerUpdated(DiscoveredServer),
    ScanComplete { source: DiscoverySource },
}

/// Progressive result batches emitted during a one-shot discovery sweep.
#[derive(Debug, Clone)]
pub struct ProgressiveDiscoveryUpdate {
    pub kind: ProgressiveDiscoveryUpdateKind,
    pub source: Option<DiscoverySource>,
    pub servers: Vec<DiscoveredServer>,
    /// Overall scan progress from 0.0 to 1.0.
    pub progress: f32,
    /// Human-readable label for what just completed or is in progress.
    pub progress_label: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProgressiveDiscoveryUpdateKind {
    PartialResults,
    ScanComplete,
}

/// Configuration for the discovery service.
#[derive(Debug, Clone)]
pub struct DiscoveryConfig {
    pub scan_ports: Vec<u16>,
    pub probe_timeout: Duration,
    pub enable_bonjour: bool,
    pub enable_tailscale: bool,
    pub enable_lan_probe: bool,
    pub enable_arp_scan: bool,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            scan_ports: DEFAULT_SCAN_PORTS.to_vec(),
            probe_timeout: Duration::from_secs(2),
            enable_bonjour: true,
            enable_tailscale: true,
            enable_lan_probe: true,
            enable_arp_scan: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Platform mDNS browser trait
// ---------------------------------------------------------------------------

/// Event from the platform-specific mDNS browser.
#[derive(Debug, Clone)]
pub enum MdnsServiceEvent {
    Found {
        name: String,
        host: String,
        port: u16,
        txt: HashMap<String, String>,
    },
    Lost {
        name: String,
    },
}

/// Platform-provided mDNS browser (iOS = NWBrowser, Android = NsdManager).
///
/// The Rust layer coordinates results; actual browsing is delegated to the
/// platform because reliable mDNS requires OS-level APIs.
#[async_trait::async_trait]
pub trait PlatformMdnsBrowser: Send + Sync {
    /// Start browsing for the given service type (e.g. `_codex._tcp.`).
    /// Returns a channel that yields discovery events.
    fn browse(&self, service_type: &str) -> mpsc::Receiver<MdnsServiceEvent>;

    /// Stop the browser.
    fn stop(&self);
}

/// A no-op mDNS browser used when no platform browser is provided.
struct NoopMdnsBrowser;

#[async_trait::async_trait]
impl PlatformMdnsBrowser for NoopMdnsBrowser {
    fn browse(&self, _service_type: &str) -> mpsc::Receiver<MdnsServiceEvent> {
        let (_tx, rx) = mpsc::channel(1);
        rx
    }

    fn stop(&self) {}
}

// ---------------------------------------------------------------------------
// DiscoveryService
// ---------------------------------------------------------------------------

/// Multi-source server discovery service.
pub struct DiscoveryService {
    config: DiscoveryConfig,
    mdns_browser: Arc<dyn PlatformMdnsBrowser>,
    servers: Arc<Mutex<HashMap<String, DiscoveredServer>>>,
    manual_servers: Arc<Mutex<Vec<(String, u16)>>>,
    running: Arc<AtomicBool>,
}

pub fn reconcile_discovered_servers(candidates: Vec<DiscoveredServer>) -> Vec<DiscoveredServer> {
    let mut map: HashMap<String, DiscoveredServer> = HashMap::new();
    for server in candidates {
        let key = discovery_identity_key(&server);
        match map.get_mut(&key) {
            Some(existing) => merge_server(existing, server),
            None => {
                map.insert(key, server);
            }
        }
    }

    let mut results: Vec<DiscoveredServer> = map.into_values().collect();
    results.sort_by(|a, b| {
        source_rank(a.source)
            .cmp(&source_rank(b.source))
            .then_with(|| a.display_name.cmp(&b.display_name))
            .then_with(|| a.host.cmp(&b.host))
            .then_with(|| a.id.cmp(&b.id))
    });
    results
}

impl DiscoveryService {
    /// Create a new discovery service with default (no-op) mDNS browser.
    pub fn new(config: DiscoveryConfig) -> Self {
        Self {
            config,
            mdns_browser: Arc::new(NoopMdnsBrowser),
            servers: Arc::new(Mutex::new(HashMap::new())),
            manual_servers: Arc::new(Mutex::new(Vec::new())),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Create with a platform-specific mDNS browser.
    pub fn with_mdns_browser(
        config: DiscoveryConfig,
        browser: Arc<dyn PlatformMdnsBrowser>,
    ) -> Self {
        Self {
            config,
            mdns_browser: browser,
            servers: Arc::new(Mutex::new(HashMap::new())),
            manual_servers: Arc::new(Mutex::new(Vec::new())),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Run a single discovery sweep across all enabled sources.
    pub async fn scan_once(&self) -> Vec<DiscoveredServer> {
        self.scan_once_with_context(&[], None).await
    }

    /// Run a single discovery sweep using pre-resolved platform mDNS seeds.
    pub async fn scan_once_with_mdns_seeds(
        &self,
        mdns_seeds: &[MdnsSeed],
    ) -> Vec<DiscoveredServer> {
        self.scan_once_with_context(mdns_seeds, None).await
    }

    /// Run a single discovery sweep using platform hints from the UI layer.
    pub async fn scan_once_with_context(
        &self,
        mdns_seeds: &[MdnsSeed],
        local_ipv4_hint: Option<&str>,
    ) -> Vec<DiscoveredServer> {
        let mut all = Vec::new();
        let local_ipv4_hint = local_ipv4_hint.and_then(parse_ipv4_hint);

        // Run all sources concurrently.
        let (lan_res, tailscale_res, bonjour_res, arp_res, manual_res) = tokio::join!(
            self.scan_lan_probe(local_ipv4_hint),
            self.scan_tailscale(),
            self.scan_bonjour_with_seeds(mdns_seeds),
            self.scan_arp(),
            self.scan_manual(),
        );

        all.extend(lan_res);
        all.extend(tailscale_res);
        all.extend(bonjour_res);
        all.extend(arp_res);
        all.extend(manual_res);

        let results = reconcile_discovered_servers(all);
        self.update_cached_servers(&results);
        results
    }

    /// Run a single discovery sweep and emit reconciled partial results as each
    /// source finishes.
    pub async fn scan_once_progressive_with_context(
        &self,
        mdns_seeds: &[MdnsSeed],
        local_ipv4_hint: Option<&str>,
        tx: &broadcast::Sender<ProgressiveDiscoveryUpdate>,
    ) -> Vec<DiscoveredServer> {
        let local_ipv4_hint = local_ipv4_hint.and_then(parse_ipv4_hint);
        let lan_probed = Arc::new(AtomicU32::new(0));
        let lan_total = self.lan_probe_host_count();
        let mut join_set = JoinSet::new();

        {
            let svc = self.clone_for_one_shot();
            let counter = Arc::clone(&lan_probed);
            join_set.spawn(async move {
                (
                    DiscoverySource::LanProbe,
                    svc.scan_lan_probe_with_progress(local_ipv4_hint, Some(counter))
                        .await,
                )
            });
        }

        {
            let svc = self.clone_for_one_shot();
            join_set.spawn(async move { (DiscoverySource::Tailscale, svc.scan_tailscale().await) });
        }

        {
            let svc = self.clone_for_one_shot();
            let seeds = mdns_seeds.to_vec();
            join_set.spawn(async move {
                (
                    DiscoverySource::Bonjour,
                    svc.scan_bonjour_with_seeds(&seeds).await,
                )
            });
        }

        {
            let svc = self.clone_for_one_shot();
            join_set.spawn(async move { (DiscoverySource::ArpScan, svc.scan_arp().await) });
        }

        {
            let svc = self.clone_for_one_shot();
            join_set.spawn(async move { (DiscoverySource::Manual, svc.scan_manual().await) });
        }

        let mut cumulative = Vec::new();
        let mut latest_results = Vec::new();
        let mut completed_weight: f32 = 0.0;
        let lan_weight = source_progress_weight(DiscoverySource::LanProbe);
        let mut lan_finished = false;

        // Emit intermediate LAN progress until all sources finish.
        loop {
            // Poll the JoinSet with a short timeout so we can emit LAN progress.
            let result =
                tokio::time::timeout(Duration::from_millis(250), join_set.join_next()).await;

            match result {
                Ok(Some(Ok((source, servers)))) => {
                    cumulative.extend(servers);
                    latest_results = reconcile_discovered_servers(cumulative.clone());
                    completed_weight += source_progress_weight(source);
                    if source == DiscoverySource::LanProbe {
                        lan_finished = true;
                    }
                    let progress = completed_weight.min(1.0);
                    let _ = tx.send(ProgressiveDiscoveryUpdate {
                        kind: ProgressiveDiscoveryUpdateKind::PartialResults,
                        source: Some(source),
                        servers: latest_results.clone(),
                        progress,
                        progress_label: Some(source_display_label(source)),
                    });
                }
                Ok(Some(Err(_))) => {
                    // Task panicked, skip
                }
                Ok(None) => {
                    // JoinSet exhausted
                    break;
                }
                Err(_) => {
                    // Timeout — emit intermediate LAN progress if still running.
                    if !lan_finished {
                        let probed = lan_probed.load(Ordering::Relaxed);
                        let lan_frac = if lan_total > 0 {
                            probed as f32 / lan_total as f32
                        } else {
                            0.0
                        };
                        let progress = (completed_weight + lan_frac * lan_weight).min(0.99);
                        let _ = tx.send(ProgressiveDiscoveryUpdate {
                            kind: ProgressiveDiscoveryUpdateKind::PartialResults,
                            source: None,
                            servers: latest_results.clone(),
                            progress,
                            progress_label: Some(format!(
                                "Scanning LAN · {}/{}",
                                probed, lan_total
                            )),
                        });
                    }
                }
            }
        }

        self.update_cached_servers(&latest_results);
        let _ = tx.send(ProgressiveDiscoveryUpdate {
            kind: ProgressiveDiscoveryUpdateKind::ScanComplete,
            source: None,
            servers: latest_results.clone(),
            progress: 1.0,
            progress_label: None,
        });
        latest_results
    }

    pub(crate) fn clone_for_one_shot(&self) -> Self {
        Self {
            config: self.config.clone(),
            mdns_browser: Arc::clone(&self.mdns_browser),
            servers: Arc::clone(&self.servers),
            manual_servers: Arc::clone(&self.manual_servers),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    fn update_cached_servers(&self, results: &[DiscoveredServer]) {
        let mut servers = self.servers.lock().unwrap();
        for server in results {
            servers.insert(server.id.clone(), server.clone());
        }
    }

    /// Start continuous scanning. Returns a broadcast receiver for events.
    ///
    /// Scans run every 30 seconds until [`stop`] is called.
    pub fn start(&self) -> broadcast::Receiver<DiscoveryEvent> {
        let (tx, rx) = broadcast::channel(128);
        self.running.store(true, Ordering::SeqCst);

        let config = self.config.clone();
        let mdns_browser = self.mdns_browser.clone();
        let servers = self.servers.clone();
        let manual_servers = self.manual_servers.clone();
        let running = self.running.clone();

        tokio::spawn(async move {
            let svc = DiscoveryService {
                config,
                mdns_browser,
                servers: servers.clone(),
                manual_servers,
                running: running.clone(),
            };

            while running.load(Ordering::SeqCst) {
                let new_results = svc.scan_once().await;

                // Diff against previous state and emit events.
                let mut prev = servers.lock().unwrap().clone();

                for server in &new_results {
                    match prev.remove(&server.id) {
                        None => {
                            let _ = tx.send(DiscoveryEvent::ServerFound(server.clone()));
                        }
                        Some(old) => {
                            if old.reachable != server.reachable
                                || old.port != server.port
                                || old.source != server.source
                            {
                                let _ = tx.send(DiscoveryEvent::ServerUpdated(server.clone()));
                            }
                        }
                    }
                }

                // Any remaining in `prev` that are stale => lost.
                let now = Instant::now();
                for (id, old) in &prev {
                    if now.duration_since(old.last_seen) > SERVER_STALE_TIMEOUT {
                        let _ = tx.send(DiscoveryEvent::ServerLost(id.clone()));
                        servers.lock().unwrap().remove(id);
                    }
                }

                // Update cache with new results.
                {
                    let mut cache = servers.lock().unwrap();
                    for server in new_results {
                        cache.insert(server.id.clone(), server);
                    }
                }

                // Emit scan-complete events for each enabled source.
                for source in &[
                    DiscoverySource::LanProbe,
                    DiscoverySource::Tailscale,
                    DiscoverySource::Bonjour,
                    DiscoverySource::ArpScan,
                ] {
                    let _ = tx.send(DiscoveryEvent::ScanComplete { source: *source });
                }

                tokio::time::sleep(CONTINUOUS_SCAN_INTERVAL).await;
            }
        });

        rx
    }

    /// Stop continuous scanning.
    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        self.mdns_browser.stop();
    }

    /// Add a manual server entry. It will be probed on the next scan.
    pub fn add_manual(&mut self, host: String, port: u16) -> DiscoveredServer {
        let server = DiscoveredServer {
            id: format!("manual-{}:{}", host, port),
            display_name: format!("{}:{}", host, port),
            host: host.clone(),
            port,
            codex_port: Some(port),
            codex_ports: vec![port],
            ssh_port: None,
            source: DiscoverySource::Manual,
            metadata: HashMap::new(),
            last_seen: Instant::now(),
            reachable: false, // will be verified on next scan
        };

        self.manual_servers.lock().unwrap().push((host, port));

        self.servers
            .lock()
            .unwrap()
            .insert(server.id.clone(), server.clone());

        server
    }

    /// Probe a single host:port for TCP connectivity.
    pub async fn probe_host(&self, host: &str, port: u16) -> bool {
        tcp_probe(host, port, self.config.probe_timeout).await
    }

    // -----------------------------------------------------------------------
    // Source-specific scan methods
    // -----------------------------------------------------------------------

    /// LAN subnet probe: detect local IP, scan /24 subnet in parallel.
    async fn scan_lan_probe(&self, local_ipv4_hint: Option<Ipv4Addr>) -> Vec<DiscoveredServer> {
        self.scan_lan_probe_with_progress(local_ipv4_hint, None)
            .await
    }

    async fn scan_lan_probe_with_progress(
        &self,
        local_ipv4_hint: Option<Ipv4Addr>,
        probed_counter: Option<Arc<AtomicU32>>,
    ) -> Vec<DiscoveredServer> {
        if !self.config.enable_lan_probe {
            return Vec::new();
        }

        let local_ip = match local_ipv4_hint.or_else(detect_local_ipv4) {
            Some(ip) => ip,
            None => {
                tracing::debug!("discovery: could not detect local IPv4 address");
                return Vec::new();
            }
        };

        let octets = local_ip.octets();
        let prefix = [octets[0], octets[1], octets[2]];
        let local_last = octets[3];

        let semaphore = Arc::new(Semaphore::new(MAX_CONCURRENT_PROBES));
        let timeout = self.config.probe_timeout;
        let ports = self.config.scan_ports.clone();

        let mut handles = Vec::with_capacity(253);

        for host_octet in 1u8..=254u8 {
            if host_octet == local_last {
                continue;
            }
            let ip = Ipv4Addr::new(prefix[0], prefix[1], prefix[2], host_octet);
            let sem = semaphore.clone();
            let ports = ports.clone();
            let counter = probed_counter.clone();

            handles.push(tokio::spawn(async move {
                let _permit = sem.acquire().await.unwrap();
                let host_str = ip.to_string();
                let reachable_ports = all_reachable_ports(&host_str, &ports, timeout).await;
                if let Some(c) = &counter {
                    c.fetch_add(1, Ordering::Relaxed);
                }
                if reachable_ports.is_empty() {
                    return None;
                }
                Some(
                    server_from_reachable_ports(
                        &host_str,
                        &reachable_ports,
                        DiscoverySource::LanProbe,
                        timeout,
                    )
                    .await,
                )
            }));
        }

        let mut results = Vec::new();
        for handle in handles {
            if let Ok(Some(server)) = handle.await {
                results.push(server);
            }
        }

        results
    }

    fn lan_probe_host_count(&self) -> u32 {
        253
    }

    /// Tailscale peer discovery via local API.
    async fn scan_tailscale(&self) -> Vec<DiscoveredServer> {
        if !self.config.enable_tailscale {
            return Vec::new();
        }

        let peers = match fetch_tailscale_peers().await {
            Ok(peers) => peers,
            Err(e) => {
                tracing::debug!("discovery: tailscale not available: {}", e);
                return Vec::new();
            }
        };

        let timeout = self.config.probe_timeout;
        let ports = self.config.scan_ports.clone();

        let mut handles = Vec::new();
        for (ip, hostname) in peers {
            let ports = ports.clone();
            handles.push(tokio::spawn(async move {
                let reachable_ports = all_reachable_ports(&ip, &ports, timeout).await;
                if reachable_ports.is_empty() {
                    return None;
                }
                let display = if hostname.is_empty() {
                    ip.clone()
                } else {
                    hostname.clone()
                };
                let mut server = server_from_reachable_ports(
                    &ip,
                    &reachable_ports,
                    DiscoverySource::Tailscale,
                    timeout,
                )
                .await;
                server.display_name = display;
                if !hostname.is_empty() {
                    server.metadata.insert("hostname".to_string(), hostname);
                }
                Some(server)
            }));
        }

        let mut results = Vec::new();
        for handle in handles {
            if let Ok(Some(server)) = handle.await {
                results.push(server);
            }
        }
        results
    }

    /// Bonjour/mDNS discovery via platform browser.
    #[cfg_attr(not(test), allow(dead_code))]
    async fn scan_bonjour(&self) -> Vec<DiscoveredServer> {
        self.scan_bonjour_with_seeds(&[]).await
    }

    async fn scan_bonjour_with_seeds(&self, seeds: &[MdnsSeed]) -> Vec<DiscoveredServer> {
        if !self.config.enable_bonjour {
            return Vec::new();
        }

        let mut mdns_seeds = seeds.to_vec();
        mdns_seeds.extend(self.collect_browser_mdns_seeds().await);
        self.scan_bonjour_seeds(mdns_seeds).await
    }

    async fn collect_browser_mdns_seeds(&self) -> Vec<MdnsSeed> {
        let mut seeds = Vec::new();

        for service_type in &["_codex._tcp.", "_ssh._tcp."] {
            let mut rx = self.mdns_browser.browse(service_type);
            let deadline = tokio::time::sleep(Duration::from_secs(5));
            tokio::pin!(deadline);

            loop {
                tokio::select! {
                    event = rx.recv() => {
                        match event {
                            Some(MdnsServiceEvent::Found { name, host, port, txt }) => {
                                seeds.push(MdnsSeed {
                                    name,
                                    host,
                                    port: (port > 0).then_some(port),
                                    service_type: (*service_type).to_string(),
                                    txt,
                                });
                            }
                            Some(MdnsServiceEvent::Lost { .. }) => {}
                            None => break,
                        }
                    }
                    _ = &mut deadline => break,
                }
            }
        }

        seeds
    }

    async fn scan_bonjour_seeds(&self, seeds: Vec<MdnsSeed>) -> Vec<DiscoveredServer> {
        let mut results = Vec::new();

        for seed in seeds {
            let host = seed.host.trim().to_string();
            if host.is_empty() {
                continue;
            }

            let display = clean_hostname(&seed.name);
            let is_codex_service = seed.service_type.starts_with("_codex.");
            let is_ssh_service = seed.service_type.starts_with("_ssh.");

            let mut codex_port = if is_codex_service { seed.port } else { None };
            let ssh_port = if is_ssh_service {
                Some(seed.port.unwrap_or(22))
            } else {
                None
            };

            let mut reachable = false;
            let known_ports: Vec<u16> = [codex_port, ssh_port].into_iter().flatten().collect();
            if !known_ports.is_empty() {
                reachable =
                    any_reachable_port(&host, &known_ports, self.config.probe_timeout).await;
            }

            if codex_port.is_none() {
                let codex_only_ports: Vec<u16> = self
                    .config
                    .scan_ports
                    .iter()
                    .copied()
                    .filter(|&p| p != SSH_PORT)
                    .collect();
                if let Some(port) =
                    first_reachable_port(&host, &codex_only_ports, self.config.probe_timeout).await
                {
                    codex_port = Some(port);
                    reachable = true;
                }
            }

            if codex_port.is_none() && ssh_port.is_none() {
                continue;
            }

            let mut metadata = seed.txt;
            metadata.insert("service_type".to_string(), seed.service_type);
            if let Some(sp) = ssh_port
                && let Some(banner) = grab_ssh_banner(&host, sp, self.config.probe_timeout).await {
                    if let Some(os) = parse_ssh_banner_os(&banner) {
                        metadata.insert("os".to_string(), os);
                    }
                    metadata.insert("ssh_banner".to_string(), banner);
                }
            let port = primary_port(codex_port, ssh_port);
            if port == 0 {
                continue;
            }

            results.push(DiscoveredServer {
                id: format!("network-{}", host),
                display_name: if display.is_empty() {
                    host.clone()
                } else {
                    display
                },
                host,
                port,
                codex_port,
                codex_ports: codex_port.into_iter().collect(),
                ssh_port,
                source: DiscoverySource::Bonjour,
                metadata,
                last_seen: Instant::now(),
                reachable,
            });
        }

        results
    }

    /// ARP table scan (Linux/Android: /proc/net/arp, macOS: `arp -a`).
    async fn scan_arp(&self) -> Vec<DiscoveredServer> {
        if !self.config.enable_arp_scan {
            return Vec::new();
        }

        let candidates = parse_arp_table();
        if candidates.is_empty() {
            return Vec::new();
        }

        let semaphore = Arc::new(Semaphore::new(MAX_CONCURRENT_PROBES));
        let timeout = self.config.probe_timeout;
        let ports = self.config.scan_ports.clone();

        let mut handles = Vec::new();
        for ip in candidates {
            let sem = semaphore.clone();
            let ports = ports.clone();
            handles.push(tokio::spawn(async move {
                let _permit = sem.acquire().await.unwrap();
                let reachable_ports = all_reachable_ports(&ip, &ports, timeout).await;
                if reachable_ports.is_empty() {
                    return None;
                }
                Some(
                    server_from_reachable_ports(
                        &ip,
                        &reachable_ports,
                        DiscoverySource::ArpScan,
                        timeout,
                    )
                    .await,
                )
            }));
        }

        let mut results = Vec::new();
        for handle in handles {
            if let Ok(Some(server)) = handle.await {
                results.push(server);
            }
        }
        results
    }

    /// Probe manually-added servers.
    async fn scan_manual(&self) -> Vec<DiscoveredServer> {
        let entries: Vec<(String, u16)> = self.manual_servers.lock().unwrap().clone();
        let timeout = self.config.probe_timeout;

        let mut handles = Vec::new();
        for (host, port) in entries {
            handles.push(tokio::spawn(async move {
                let reachable = tcp_probe(&host, port, timeout).await;
                DiscoveredServer {
                    id: format!("manual-{}:{}", host, port),
                    display_name: format!("{}:{}", host, port),
                    host,
                    port,
                    codex_port: Some(port),
                    codex_ports: vec![port],
                    ssh_port: None,
                    source: DiscoverySource::Manual,
                    metadata: HashMap::new(),
                    last_seen: Instant::now(),
                    reachable,
                }
            }));
        }

        let mut results = Vec::new();
        for handle in handles {
            if let Ok(server) = handle.await {
                results.push(server);
            }
        }
        results
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// TCP connect probe with timeout.
async fn tcp_probe(host: &str, port: u16, timeout: Duration) -> bool {
    let addr = format!("{}:{}", host, port);
    tokio::time::timeout(timeout, TcpStream::connect(&addr))
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false)
}

async fn any_reachable_port(host: &str, ports: &[u16], timeout: Duration) -> bool {
    let probes = ports.iter().map(|&port| tcp_probe(host, port, timeout));
    join_all(probes)
        .await
        .into_iter()
        .any(|reachable| reachable)
}

async fn all_reachable_ports(host: &str, ports: &[u16], timeout: Duration) -> Vec<u16> {
    let probes = ports.iter().map(|&port| tcp_probe(host, port, timeout));
    let results = join_all(probes).await;
    ports
        .iter()
        .copied()
        .zip(results.into_iter())
        .filter_map(|(port, reachable)| reachable.then_some(port))
        .collect()
}

/// Well-known SSH port.
const SSH_PORT: u16 = 22;

/// Build a `DiscoveredServer` from the set of reachable ports, correctly
/// classifying SSH vs Codex ports. Grabs the SSH banner when port 22 is
/// open to identify the remote OS.
async fn server_from_reachable_ports(
    host: &str,
    reachable_ports: &[u16],
    source: DiscoverySource,
    probe_timeout: Duration,
) -> DiscoveredServer {
    let ssh_port = reachable_ports.contains(&SSH_PORT).then_some(SSH_PORT);
    let codex_ports: Vec<u16> = reachable_ports
        .iter()
        .copied()
        .filter(|&p| p != SSH_PORT)
        .collect();
    let codex_port = codex_ports.first().copied();
    let port = primary_port(codex_port, ssh_port);

    let mut metadata = HashMap::new();
    if ssh_port.is_some()
        && let Some(banner) = grab_ssh_banner(host, SSH_PORT, probe_timeout).await {
            if let Some(os) = parse_ssh_banner_os(&banner) {
                metadata.insert("os".to_string(), os);
            }
            metadata.insert("ssh_banner".to_string(), banner);
        }

    DiscoveredServer {
        id: format!("network-{}", host),
        display_name: host.to_string(),
        host: host.to_string(),
        port,
        codex_port,
        codex_ports,
        ssh_port,
        source,
        metadata,
        last_seen: Instant::now(),
        reachable: true,
    }
}

/// Connect to an SSH port and read the server's version banner.
///
/// The SSH protocol requires the server to send its banner immediately
/// after TCP connect, so this adds negligible latency on top of the
/// probe we already did.
async fn grab_ssh_banner(host: &str, port: u16, timeout: Duration) -> Option<String> {
    let addr = format!("{}:{}", host, port);
    let mut stream = tokio::time::timeout(timeout, TcpStream::connect(&addr))
        .await
        .ok()?
        .ok()?;

    let mut buf = vec![0u8; 256];
    let n = tokio::time::timeout(Duration::from_millis(500), stream.read(&mut buf))
        .await
        .ok()?
        .ok()?;

    let line = String::from_utf8_lossy(&buf[..n]);
    let banner = line.lines().next()?.trim().to_string();
    banner.starts_with("SSH-").then_some(banner)
}

/// Extract an OS name from an SSH version banner.
///
/// Common banners:
///   SSH-2.0-OpenSSH_for_Windows_8.1
///   SSH-2.0-OpenSSH_9.5 Windows_NT
///   SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6
///   SSH-2.0-OpenSSH_9.2p1 Debian-5+deb12u1
///   SSH-2.0-OpenSSH_9.2p1 Raspbian-5+deb12u1
fn parse_ssh_banner_os(banner: &str) -> Option<String> {
    let lower = banner.to_lowercase();
    if lower.contains("windows") {
        Some("Windows".to_string())
    } else if lower.contains("raspbian") {
        Some("Raspbian".to_string())
    } else if lower.contains("ubuntu") {
        Some("Ubuntu".to_string())
    } else if lower.contains("debian") {
        Some("Debian".to_string())
    } else if lower.contains("fedora") {
        Some("Fedora".to_string())
    } else if lower.contains("red hat") || lower.contains("redhat") {
        Some("Red Hat".to_string())
    } else if lower.contains("freebsd") {
        Some("FreeBSD".to_string())
    } else {
        // Bare OpenSSH (macOS, some minimal Linux) or non-OpenSSH servers
        // (dropbear, libssh). Don't guess — let the platform layer use
        // discovery source (e.g. Bonjour → macOS) to infer the OS.
        None
    }
}

async fn first_reachable_port(host: &str, ports: &[u16], timeout: Duration) -> Option<u16> {
    let probes = ports.iter().map(|&port| tcp_probe(host, port, timeout));
    let results = join_all(probes).await;
    ports
        .iter()
        .copied()
        .zip(results.into_iter())
        .find_map(|(port, reachable)| reachable.then_some(port))
}

fn primary_port(codex_port: Option<u16>, ssh_port: Option<u16>) -> u16 {
    codex_port.or(ssh_port).unwrap_or_default()
}

fn discovery_identity_key(server: &DiscoveredServer) -> String {
    normalized_host_key(&server.host).unwrap_or_else(|| server.id.clone())
}

fn normalized_host_key(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let unbracketed = trimmed.trim_start_matches('[').trim_end_matches(']');
    let without_scope = match unbracketed.split_once('%') {
        Some((host, _)) => host,
        None => unbracketed,
    };
    let normalized = without_scope.trim().to_lowercase();
    (!normalized.is_empty()).then_some(normalized)
}

fn merge_server(existing: &mut DiscoveredServer, candidate: DiscoveredServer) {
    let prefer_candidate = source_rank(candidate.source) < source_rank(existing.source);
    let candidate_name_is_better =
        existing.display_name == existing.host && candidate.display_name != candidate.host;

    if prefer_candidate {
        existing.source = candidate.source;
    }
    if prefer_candidate || candidate_name_is_better {
        existing.display_name = candidate.display_name.clone();
    }
    if prefer_candidate && !candidate.host.is_empty() {
        existing.host = candidate.host.clone();
    }
    if candidate.codex_port.is_some() && (existing.codex_port.is_none() || prefer_candidate) {
        existing.codex_port = candidate.codex_port;
    }
    merge_codex_ports(existing, &candidate, prefer_candidate);
    if candidate.ssh_port.is_some() && (existing.ssh_port.is_none() || prefer_candidate) {
        existing.ssh_port = candidate.ssh_port;
    }
    existing.metadata.extend(candidate.metadata);
    existing.reachable |= candidate.reachable;
    if candidate.last_seen > existing.last_seen {
        existing.last_seen = candidate.last_seen;
    }
    let merged_port = primary_port(existing.codex_port, existing.ssh_port);
    if merged_port > 0 {
        existing.port = merged_port;
    } else if prefer_candidate && candidate.port > 0 {
        existing.port = candidate.port;
    }
    existing.codex_port = existing.codex_ports.first().copied();
}

fn merge_codex_ports(
    existing: &mut DiscoveredServer,
    candidate: &DiscoveredServer,
    prefer_candidate: bool,
) {
    let mut ports = if prefer_candidate {
        candidate.codex_ports.clone()
    } else {
        existing.codex_ports.clone()
    };
    let incoming = if prefer_candidate {
        &existing.codex_ports
    } else {
        &candidate.codex_ports
    };
    for port in incoming {
        if !ports.contains(port) {
            ports.push(*port);
        }
    }
    ports.sort_unstable();
    existing.codex_ports = ports;
}

/// Detect the local IPv4 address by binding a UDP socket to a public address.
///
/// This is a standard trick: the OS picks the correct source address for the
/// route to 8.8.8.8 without actually sending any traffic.
fn detect_local_ipv4() -> Option<Ipv4Addr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_loopback() => Some(ip),
        _ => None,
    }
}

fn parse_ipv4_hint(value: &str) -> Option<Ipv4Addr> {
    value
        .parse::<Ipv4Addr>()
        .ok()
        .filter(|ip| !ip.is_loopback())
}

/// Fetch the list of Tailscale peers from the local API.
///
/// Talks raw HTTP/1.1 over a TCP connection to the Tailscale local API daemon.
/// On macOS this is at 127.0.0.1:41112, on Linux/Android at 100.100.100.100:80.
async fn fetch_tailscale_peers() -> Result<Vec<(String, String)>, String> {
    // Try both known endpoints.
    let endpoints = [
        ("100.100.100.100", 80), // Linux / Android
        ("127.0.0.1", 41112),    // macOS
    ];

    for (host, port) in &endpoints {
        match fetch_tailscale_status(host, *port).await {
            Ok(peers) => return Ok(peers),
            Err(_) => continue,
        }
    }

    Err("could not reach tailscale local API".to_string())
}

/// Raw HTTP GET to the Tailscale local API, parsing peer list from JSON.
async fn fetch_tailscale_status(host: &str, port: u16) -> Result<Vec<(String, String)>, String> {
    let addr = format!("{}:{}", host, port);
    let mut stream = tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(&addr))
        .await
        .map_err(|_| "timeout")?
        .map_err(|e| e.to_string())?;

    let request = format!(
        "GET /localapi/v0/status HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
        host
    );
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| e.to_string())?;

    let mut buf = Vec::with_capacity(64 * 1024);
    tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(&mut buf))
        .await
        .map_err(|_| "read timeout")?
        .map_err(|e| e.to_string())?;

    let response = String::from_utf8_lossy(&buf);

    // Find the start of the JSON body (after blank line).
    let body_start = response
        .find("\r\n\r\n")
        .map(|i| i + 4)
        .ok_or("no HTTP body")?;
    let body = &response[body_start..];

    let json: serde_json::Value =
        serde_json::from_str(body).map_err(|e| format!("JSON parse error: {}", e))?;

    let peers_obj = json
        .get("Peer")
        .and_then(|v| v.as_object())
        .ok_or("no Peer object")?;

    let mut results = Vec::new();
    for (_key, peer) in peers_obj {
        // Skip offline peers.
        if let Some(false) = peer.get("Online").and_then(|v| v.as_bool()) {
            continue;
        }

        let hostname = peer
            .get("HostName")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();

        let hostname = if hostname.is_empty() {
            peer.get("DNSName")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .trim_end_matches('.')
                .to_string()
        } else {
            hostname
        };

        let ips = match peer.get("TailscaleIPs").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => continue,
        };

        for ip_val in ips {
            if let Some(ip_str) = ip_val.as_str() {
                let ip_str = ip_str.trim();
                if is_likely_ipv4(ip_str) {
                    results.push((ip_str.to_string(), hostname.clone()));
                    break;
                }
            }
        }
    }

    Ok(results)
}

/// Parse ARP table to find candidate IPs.
///
/// On Linux/Android reads `/proc/net/arp`.
/// On macOS, runs `arp -a` and parses the output.
fn parse_arp_table() -> Vec<String> {
    let mut candidates = Vec::new();

    // Try /proc/net/arp first (Linux/Android).
    if let Ok(content) = std::fs::read_to_string("/proc/net/arp") {
        for line in content.lines().skip(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 6 {
                continue;
            }
            let ip = parts[0];
            let flags = parts[2];
            if ip == "127.0.0.1" || ip == "0.0.0.0" {
                continue;
            }
            // 0x2 = complete entry
            if flags != "0x2" {
                continue;
            }
            if is_likely_ipv4(ip) {
                candidates.push(ip.to_string());
            }
        }
        return candidates;
    }

    // macOS fallback: run `arp -a` and parse output.
    // Format: hostname (ip) at mac on iface ...
    if let Ok(output) = std::process::Command::new("arp").arg("-a").output() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if let Some(start) = line.find('(')
                && let Some(end) = line.find(')') {
                    let ip = &line[start + 1..end];
                    if ip != "127.0.0.1" && is_likely_ipv4(ip) {
                        // Skip incomplete entries
                        if !line.contains("incomplete") {
                            candidates.push(ip.to_string());
                        }
                    }
                }
        }
    }

    candidates
}

/// Check if a string looks like a valid IPv4 address.
fn is_likely_ipv4(value: &str) -> bool {
    let parts: Vec<&str> = value.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    parts.iter().all(|p| p.parse::<u8>().is_ok())
}

/// Remove `.local` suffix and trailing dots from a hostname.
fn clean_hostname(name: &str) -> String {
    let mut s = name.trim().to_string();
    // Strip trailing dot first (e.g. "myhost.local." → "myhost.local").
    if s.ends_with('.') {
        s.pop();
    }
    if s.to_lowercase().ends_with(".local") {
        s.truncate(s.len() - ".local".len());
    }
    s
}

/// Approximate time-weight for each source, used to compute a smooth
/// progress fraction. LAN probe dominates wall-clock time.
fn source_progress_weight(source: DiscoverySource) -> f32 {
    match source {
        DiscoverySource::Manual | DiscoverySource::Bundled => 0.02,
        DiscoverySource::ArpScan => 0.05,
        DiscoverySource::Bonjour => 0.13,
        DiscoverySource::Tailscale => 0.15,
        DiscoverySource::LanProbe => 0.65,
    }
}

fn source_display_label(source: DiscoverySource) -> String {
    match source {
        DiscoverySource::LanProbe => "LAN scan".to_string(),
        DiscoverySource::Tailscale => "Tailscale".to_string(),
        DiscoverySource::Bonjour => "Bonjour".to_string(),
        DiscoverySource::ArpScan => "ARP scan".to_string(),
        DiscoverySource::Manual => "Saved servers".to_string(),
        DiscoverySource::Bundled => "Local".to_string(),
    }
}

/// Rank discovery sources for deduplication priority (lower = better).
fn source_rank(source: DiscoverySource) -> u8 {
    match source {
        DiscoverySource::Bundled => 0,
        DiscoverySource::Bonjour => 1,
        DiscoverySource::Tailscale => 2,
        DiscoverySource::LanProbe => 3,
        DiscoverySource::ArpScan => 4,
        DiscoverySource::Manual => 5,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_likely_ipv4() {
        assert!(is_likely_ipv4("192.168.1.1"));
        assert!(is_likely_ipv4("10.0.0.1"));
        assert!(is_likely_ipv4("0.0.0.0"));
        assert!(is_likely_ipv4("255.255.255.255"));
        assert!(!is_likely_ipv4("not-an-ip"));
        assert!(!is_likely_ipv4("192.168.1"));
        assert!(!is_likely_ipv4("192.168.1.256"));
        assert!(!is_likely_ipv4("::1"));
        assert!(!is_likely_ipv4(""));
    }

    #[test]
    fn test_clean_hostname() {
        assert_eq!(clean_hostname("myhost.local"), "myhost");
        assert_eq!(clean_hostname("myhost.local."), "myhost");
        assert_eq!(clean_hostname("myhost.LOCAL"), "myhost");
        assert_eq!(clean_hostname("myhost"), "myhost");
        assert_eq!(clean_hostname("  myhost  "), "myhost");
        assert_eq!(clean_hostname(""), "");
    }

    #[test]
    fn test_source_rank_ordering() {
        assert!(source_rank(DiscoverySource::Bundled) < source_rank(DiscoverySource::Bonjour));
        assert!(source_rank(DiscoverySource::Bonjour) < source_rank(DiscoverySource::Tailscale));
        assert!(source_rank(DiscoverySource::Tailscale) < source_rank(DiscoverySource::LanProbe));
        assert!(source_rank(DiscoverySource::LanProbe) < source_rank(DiscoverySource::ArpScan));
        assert!(source_rank(DiscoverySource::ArpScan) < source_rank(DiscoverySource::Manual));
    }

    #[test]
    fn test_default_config() {
        let config = DiscoveryConfig::default();
        assert_eq!(config.scan_ports, vec![8390, 9234, 22]);
        assert_eq!(config.probe_timeout, Duration::from_secs(2));
        assert!(config.enable_bonjour);
        assert!(config.enable_tailscale);
        assert!(config.enable_lan_probe);
        assert!(config.enable_arp_scan);
    }

    #[test]
    fn test_detect_local_ipv4() {
        // This should return Some on any machine with network access, None otherwise.
        // We just verify it doesn't panic.
        let _ip = detect_local_ipv4();
    }

    #[test]
    fn test_add_manual_server() {
        let config = DiscoveryConfig::default();
        let mut svc = DiscoveryService::new(config);

        let server = svc.add_manual("10.0.0.50".to_string(), 8390);
        assert_eq!(server.id, "manual-10.0.0.50:8390");
        assert_eq!(server.host, "10.0.0.50");
        assert_eq!(server.port, 8390);
        assert_eq!(server.source, DiscoverySource::Manual);
        assert!(!server.reachable);

        // Verify it's in the internal state.
        let manual = svc.manual_servers.lock().unwrap();
        assert_eq!(manual.len(), 1);
        assert_eq!(manual[0], ("10.0.0.50".to_string(), 8390));
    }

    #[tokio::test]
    async fn test_probe_host_unreachable() {
        let config = DiscoveryConfig {
            probe_timeout: Duration::from_millis(100),
            ..Default::default()
        };
        let svc = DiscoveryService::new(config);

        // Probe a non-routable address — should return false quickly.
        let reachable = svc.probe_host("192.0.2.1", 9999).await;
        assert!(!reachable);
    }

    #[tokio::test]
    async fn test_scan_once_with_all_disabled() {
        let config = DiscoveryConfig {
            enable_bonjour: false,
            enable_tailscale: false,
            enable_lan_probe: false,
            enable_arp_scan: false,
            probe_timeout: Duration::from_millis(100),
            ..Default::default()
        };
        let svc = DiscoveryService::new(config);
        let results = svc.scan_once().await;
        // With everything disabled, should get no results (no manual entries either).
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn test_scan_manual_servers() {
        let config = DiscoveryConfig {
            enable_bonjour: false,
            enable_tailscale: false,
            enable_lan_probe: false,
            enable_arp_scan: false,
            probe_timeout: Duration::from_millis(100),
            ..Default::default()
        };
        let mut svc = DiscoveryService::new(config);
        svc.add_manual("192.0.2.1".to_string(), 8390);

        let results = svc.scan_once().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].host, "192.0.2.1");
        assert_eq!(results[0].source, DiscoverySource::Manual);
        // Non-routable, so not reachable.
        assert!(!results[0].reachable);
    }

    #[tokio::test]
    async fn test_start_stop_continuous() {
        let config = DiscoveryConfig {
            enable_bonjour: false,
            enable_tailscale: false,
            enable_lan_probe: false,
            enable_arp_scan: false,
            probe_timeout: Duration::from_millis(50),
            ..Default::default()
        };
        let svc = DiscoveryService::new(config);

        let _rx = svc.start();
        // Let it run briefly.
        tokio::time::sleep(Duration::from_millis(100)).await;
        svc.stop();
        // Should not panic or hang.
    }

    #[test]
    #[ignore] // Hits real system state (arp table / tailscale); slow on dev machines.
    fn test_parse_arp_table_doesnt_panic() {
        let _candidates = parse_arp_table();
    }

    #[tokio::test]
    #[ignore]
    async fn test_tailscale_peers_handles_unavailable() {
        let result = fetch_tailscale_peers().await;
        let _ = result;
    }

    #[test]
    fn test_discovered_server_clone() {
        let server = DiscoveredServer {
            id: "test-1".to_string(),
            display_name: "Test".to_string(),
            host: "10.0.0.1".to_string(),
            port: 8390,
            codex_port: Some(8390),
            codex_ports: vec![8390],
            ssh_port: None,
            source: DiscoverySource::LanProbe,
            metadata: HashMap::new(),
            last_seen: Instant::now(),
            reachable: true,
        };
        let cloned = server.clone();
        assert_eq!(cloned.id, server.id);
        assert_eq!(cloned.host, server.host);
        assert_eq!(cloned.source, server.source);
    }

    #[test]
    fn reconcile_prefers_better_source_and_codex_port() {
        let older = DiscoveredServer {
            id: "server-1".to_string(),
            display_name: "10.0.0.2".to_string(),
            host: "10.0.0.2".to_string(),
            port: 22,
            codex_port: None,
            codex_ports: vec![],
            ssh_port: Some(22),
            source: DiscoverySource::Manual,
            metadata: HashMap::new(),
            last_seen: Instant::now(),
            reachable: true,
        };
        let newer = DiscoveredServer {
            id: "server-1".to_string(),
            display_name: "Studio".to_string(),
            host: "10.0.0.2".to_string(),
            port: 8390,
            codex_port: Some(8390),
            codex_ports: vec![8390],
            ssh_port: Some(22),
            source: DiscoverySource::Bonjour,
            metadata: HashMap::new(),
            last_seen: Instant::now(),
            reachable: true,
        };

        let reconciled = reconcile_discovered_servers(vec![older, newer]);
        assert_eq!(reconciled.len(), 1);
        assert_eq!(reconciled[0].source, DiscoverySource::Bonjour);
        assert_eq!(reconciled[0].display_name, "Studio");
        assert_eq!(reconciled[0].codex_port, Some(8390));
        assert_eq!(reconciled[0].port, 8390);
    }

    #[tokio::test]
    #[ignore] // Probes a TEST-NET IP; can stall depending on network config.
    async fn test_bonjour_with_mock_browser() {
        struct MockBrowser;

        #[async_trait::async_trait]
        impl PlatformMdnsBrowser for MockBrowser {
            fn browse(&self, _service_type: &str) -> mpsc::Receiver<MdnsServiceEvent> {
                let (tx, rx) = mpsc::channel(8);
                tokio::spawn(async move {
                    let _ = tx
                        .send(MdnsServiceEvent::Found {
                            name: "test-server.local".to_string(),
                            host: "192.0.2.42".to_string(),
                            port: 8390,
                            txt: HashMap::new(),
                        })
                        .await;
                });
                rx
            }

            fn stop(&self) {}
        }

        let config = DiscoveryConfig {
            enable_bonjour: true,
            enable_tailscale: false,
            enable_lan_probe: false,
            enable_arp_scan: false,
            probe_timeout: Duration::from_millis(100),
            ..Default::default()
        };
        let svc = DiscoveryService::with_mdns_browser(config, Arc::new(MockBrowser));

        let results = svc.scan_bonjour().await;
        // 192.0.2.42 is TEST-NET-1 (RFC 5737) — typically unreachable.
        // If the probe fails the result list will be empty; if the
        // environment happens to route it, verify the entry is well-formed.
        for srv in &results {
            assert_eq!(srv.source, DiscoverySource::Bonjour);
            assert!(!srv.host.is_empty());
            assert!(srv.port > 0);
        }
    }
}
