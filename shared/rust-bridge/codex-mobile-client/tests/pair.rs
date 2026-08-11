//! End-to-end tests for the iPhone ↔ Mac pair protocol.
//!
//! These run as a separate compilation unit so they survive transient
//! upstream-codex test drift that breaks the lib's unit-test build.

use std::time::Duration;

use codex_mobile_client::pair::{
    PairClientHandle, PairEvent, PairHostHandle, pair_from_iphone, start_pair_host,
};

async fn wait_for_host(
    handle: &PairHostHandle,
    mut want: impl FnMut(&PairEvent) -> bool,
) -> PairEvent {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(ev) = handle.poll_event().await
            && want(&ev) {
                return ev;
            }
        if tokio::time::Instant::now() >= deadline {
            panic!("timeout waiting for host event");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn wait_for_client(
    handle: &PairClientHandle,
    mut want: impl FnMut(&PairEvent) -> bool,
) -> PairEvent {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(ev) = handle.poll_event().await
            && want(&ev) {
                return ev;
            }
        if tokio::time::Instant::now() >= deadline {
            panic!("timeout waiting for client event");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn end_to_end_pair_accept() {
    let (host, info) = start_pair_host("MacBook".to_string(), "mac-uuid-123".to_string(), 8390)
        .await
        .expect("start pair host");
    assert!(info.port > 0);
    assert!(info.txt_entries.iter().any(|t| t.starts_with("mac-id=")));
    assert!(info.txt_entries.iter().any(|t| t == "codex-port=8390"));

    host.set_ni_discovery_token("MAC_TOKEN".into()).await;

    let client = pair_from_iphone(
        "127.0.0.1".to_string(),
        info.port,
        "Daniel's iPhone".to_string(),
        "PHONE_TOKEN".to_string(),
    )
    .await
    .expect("connect client");

    // Host sees the hello
    let hello = wait_for_host(host.as_ref(), |ev| {
        matches!(ev, PairEvent::HostPeerConnected { .. })
    })
    .await;
    match hello {
        PairEvent::HostPeerConnected {
            device_name,
            ni_discovery_token_b64,
        } => {
            assert_eq!(device_name, "Daniel's iPhone");
            assert_eq!(ni_discovery_token_b64, "PHONE_TOKEN");
        }
        other => panic!("unexpected: {other:?}"),
    }

    // Client sees the hello_ack
    let ack = wait_for_client(client.as_ref(), |ev| {
        matches!(ev, PairEvent::ClientPeerAccepted { .. })
    })
    .await;
    match ack {
        PairEvent::ClientPeerAccepted {
            ni_discovery_token_b64,
        } => assert_eq!(ni_discovery_token_b64, "MAC_TOKEN"),
        other => panic!("unexpected: {other:?}"),
    }

    // iPhone walks close, sends pair_request
    client.submit_pair_request(Some(0.4)).unwrap();
    let req = wait_for_host(host.as_ref(), |ev| {
        matches!(ev, PairEvent::HostPairRequest { .. })
    })
    .await;
    match req {
        PairEvent::HostPairRequest { distance_m } => assert_eq!(distance_m, Some(0.4)),
        other => panic!("unexpected: {other:?}"),
    }

    // User taps Accept on Mac
    host.accept_pair_request(true, "192.168.1.42".into(), 8390)
        .await
        .unwrap();
    let accepted = wait_for_client(client.as_ref(), |ev| {
        matches!(ev, PairEvent::ClientPairAccepted { .. })
    })
    .await;
    match accepted {
        PairEvent::ClientPairAccepted {
            codex_ws_url,
            lan_ip,
        } => {
            assert_eq!(lan_ip, "192.168.1.42");
            assert_eq!(codex_ws_url, "ws://192.168.1.42:8390");
        }
        other => panic!("unexpected: {other:?}"),
    }

    host.stop().await;
    client.stop().await;
}

#[tokio::test]
async fn end_to_end_pair_reject() {
    let (host, info) = start_pair_host("MacBook".to_string(), "mac-uuid-123".to_string(), 8390)
        .await
        .expect("start pair host");
    host.set_ni_discovery_token("MAC_TOKEN".into()).await;

    let client = pair_from_iphone(
        "127.0.0.1".to_string(),
        info.port,
        "iPhone".to_string(),
        "PHONE_TOKEN".to_string(),
    )
    .await
    .expect("connect client");

    wait_for_host(host.as_ref(), |ev| {
        matches!(ev, PairEvent::HostPeerConnected { .. })
    })
    .await;
    wait_for_client(client.as_ref(), |ev| {
        matches!(ev, PairEvent::ClientPeerAccepted { .. })
    })
    .await;

    client.submit_pair_request(None).unwrap();
    wait_for_host(host.as_ref(), |ev| {
        matches!(ev, PairEvent::HostPairRequest { .. })
    })
    .await;

    host.accept_pair_request(false, String::new(), 0)
        .await
        .unwrap();
    let ev = wait_for_client(client.as_ref(), |ev| {
        matches!(ev, PairEvent::PeerRejected { .. })
    })
    .await;
    assert!(matches!(ev, PairEvent::PeerRejected { .. }));

    host.stop().await;
    client.stop().await;
}

#[tokio::test]
async fn distance_update_surfaces_on_host() {
    let (host, info) = start_pair_host("MacBook".to_string(), "mac-uuid-123".to_string(), 8390)
        .await
        .expect("start pair host");
    host.set_ni_discovery_token("MAC_TOKEN".into()).await;

    let client = pair_from_iphone(
        "127.0.0.1".to_string(),
        info.port,
        "iPhone".to_string(),
        "PHONE_TOKEN".to_string(),
    )
    .await
    .expect("connect client");

    wait_for_host(host.as_ref(), |ev| {
        matches!(ev, PairEvent::HostPeerConnected { .. })
    })
    .await;
    client.submit_ni_distance(2.5).unwrap();
    let ev = wait_for_host(host.as_ref(), |ev| {
        matches!(ev, PairEvent::DistanceUpdate { .. })
    })
    .await;
    match ev {
        PairEvent::DistanceUpdate { distance_m } => assert!((distance_m - 2.5).abs() < 0.01),
        other => panic!("unexpected: {other:?}"),
    }

    host.stop().await;
    client.stop().await;
}
