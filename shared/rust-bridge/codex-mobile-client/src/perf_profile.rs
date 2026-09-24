//! Reproducible, ignored micro-profiles for UI-latency store paths.

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::HashSet;
use std::hint::black_box;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use codex_app_server_protocol::{ThreadItem, Turn, TurnItemsView, TurnStatus};

use crate::conversation::{HydrationOptions, hydrate_turns};
use crate::conversation_uniffi::{
    HydratedAssistantMessageData, HydratedConversationItem, HydratedConversationItemContent,
};
use crate::session::events::UiEvent;
use crate::store::{AppSnapshotRecord, AppStoreReducer, ThreadSnapshot};
use crate::types::{ThreadInfo, ThreadKey, ThreadSummaryStatus};

struct CountingAllocator;
static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static ALLOCATED_BYTES: AtomicU64 = AtomicU64::new(0);
static PROFILE_LOCK: Mutex<()> = Mutex::new(());

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        ALLOCATED_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        ALLOCATED_BYTES.fetch_add(new_size as u64, Ordering::Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[derive(Clone, Copy)]
struct Sample {
    elapsed: Duration,
    allocations: u64,
    bytes: u64,
}

fn measure(mut operation: impl FnMut()) -> Vec<Sample> {
    for _ in 0..3 {
        operation();
    }
    let mut samples = Vec::with_capacity(15);
    for _ in 0..15 {
        ALLOCATIONS.store(0, Ordering::Relaxed);
        ALLOCATED_BYTES.store(0, Ordering::Relaxed);
        let start = Instant::now();
        operation();
        samples.push(Sample {
            elapsed: start.elapsed(),
            allocations: ALLOCATIONS.load(Ordering::Relaxed),
            bytes: ALLOCATED_BYTES.load(Ordering::Relaxed),
        });
    }
    samples
}

fn report(name: &str, mut samples: Vec<Sample>) {
    samples.sort_by_key(|sample| sample.elapsed);
    let median = samples[samples.len() / 2];
    let p95 = samples[(samples.len() * 95).div_ceil(100) - 1];
    println!(
        "PERF {name}: median_us={} p95_us={} median_allocs={} median_bytes={} p95_allocs={} p95_bytes={}",
        median.elapsed.as_micros(),
        p95.elapsed.as_micros(),
        median.allocations,
        median.bytes,
        p95.allocations,
        p95.bytes
    );
}

fn thread_info(id: String, updated_at: i64) -> ThreadInfo {
    ThreadInfo {
        title: Some(format!("Thread {id}")),
        id,
        model: Some("gpt-5".into()),
        status: ThreadSummaryStatus::Idle,
        preview: Some("realistic thread preview text".repeat(4)),
        cwd: Some("/Users/example/a-project".into()),
        path: None,
        model_provider: Some("openai".into()),
        agent_nickname: None,
        agent_role: None,
        parent_thread_id: None,
        forked_from_id: None,
        agent_status: None,
        created_at: Some(updated_at - 100),
        updated_at: Some(updated_at),
    }
}

fn assistant_item(id: usize, bytes: usize) -> HydratedConversationItem {
    HydratedConversationItem {
        id: format!("item-{id}"),
        content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
            text: "x".repeat(bytes),
            agent_nickname: None,
            agent_role: None,
            phase: None,
        }),
        source_turn_id: Some(format!("turn-{}", id / 4)),
        source_turn_index: Some((id / 4) as u32),
        timestamp: Some(id as f64),
        is_from_user_turn_boundary: false,
    }
}

fn populated_store(
    thread_count: usize,
    items_per_thread: usize,
    item_bytes: usize,
) -> AppStoreReducer {
    let store = AppStoreReducer::new();
    for index in 0..thread_count {
        let server = index % 10;
        let server_id = format!("server-{server}");
        let mut thread = ThreadSnapshot::from_info(
            &server_id,
            thread_info(format!("thread-{index}"), index as i64),
        );
        thread.items = (0..items_per_thread)
            .map(|item| assistant_item(item, item_bytes))
            .collect();
        store.upsert_thread_snapshot(thread);
    }
    store
}

#[test]
#[ignore]
fn perf_profile_snapshot_projection() {
    let _profile_guard = PROFILE_LOCK.lock().unwrap();
    for (threads, items, bytes) in [(50, 200, 128), (1_000, 200, 128), (1, 2_000, 50_000)] {
        let store = populated_store(threads, items, bytes);
        report(
            &format!("snapshot_clone threads={threads} items={items} item_bytes={bytes}"),
            measure(|| {
                black_box(store.snapshot());
            }),
        );
        report(
            &format!(
                "snapshot_clone_projection threads={threads} items={items} item_bytes={bytes}"
            ),
            measure(|| {
                black_box(AppSnapshotRecord::try_from(store.snapshot()).unwrap());
            }),
        );
    }
}

#[test]
#[ignore]
fn perf_profile_update_emission_and_streaming() {
    let _profile_guard = PROFILE_LOCK.lock().unwrap();
    for (items, initial_bytes) in [(200, 20_000), (2_000, 100_000)] {
        let store = populated_store(1, items, 128);
        let key = ThreadKey {
            server_id: "server-0".into(),
            thread_id: "thread-0".into(),
        };
        store.apply_ui_event(&UiEvent::MessageDelta {
            key: key.clone(),
            item_id: "stream".into(),
            delta: "x".repeat(initial_bytes),
        });
        let delta = "abcdefghij".to_string();
        report(
            &format!("stream_1000 items={items} initial_bytes={initial_bytes}"),
            measure(|| {
                for _ in 0..1_000 {
                    store.apply_ui_event(&UiEvent::MessageDelta {
                        key: key.clone(),
                        item_id: "stream".into(),
                        delta: delta.clone(),
                    });
                }
            }),
        );
        report(
            &format!("ThreadUpserted items={items}"),
            measure(|| store.emit_thread_upsert(&key)),
        );
        let mut changed_item = assistant_item(items + 1, initial_bytes);
        report(
            &format!("ThreadItemChanged items={items} item_bytes={initial_bytes}"),
            measure(|| {
                changed_item.timestamp = changed_item.timestamp.map(|value| value + 1.0);
                store.emit_thread_item_changed(&key, changed_item.clone());
            }),
        );
        report(
            &format!("ThreadStreamingDelta items={items}"),
            measure(|| {
                store.emit_thread_streaming_delta(
                    &key,
                    "stream",
                    crate::store::ThreadStreamingDeltaKind::AssistantText,
                    &delta,
                )
            }),
        );
    }
}

#[test]
#[ignore]
fn perf_profile_thread_list_sync() {
    let _profile_guard = PROFILE_LOCK.lock().unwrap();
    let pages = (0..10)
        .map(|server| {
            (0..100)
                .map(|index| thread_info(format!("s{server}-thread-{index}"), index))
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    report(
        "thread_list_upsert_finalize servers=10 threads=1000",
        measure(|| {
            let store = AppStoreReducer::new();
            for (server, page) in pages.iter().enumerate() {
                let server_id = format!("server-{server}");
                store.upsert_thread_list_page(&server_id, page);
                let ids = page
                    .iter()
                    .map(|info| info.id.clone())
                    .collect::<HashSet<_>>();
                store.finalize_thread_list_sync(&server_id, &ids);
            }
            black_box(store.snapshot());
        }),
    );
}

#[test]
#[ignore]
fn perf_profile_conversation_hydration() {
    let _profile_guard = PROFILE_LOCK.lock().unwrap();
    let turns = (0..20)
        .map(|turn| Turn {
            id: format!("turn-{turn}"),
            items: (0..100)
                .map(|item| ThreadItem::AgentMessage {
                    id: format!("item-{turn}-{item}"),
                    text: "assistant response text ".repeat(40),
                    phase: None,
                    memory_citation: None,
                    delivery: None,
                    questions: None,
                })
                .collect(),
            items_view: TurnItemsView::Full,
            status: TurnStatus::Completed,
            error: None,
            started_at: Some(turn),
            completed_at: Some(turn + 1),
            duration_ms: Some(1_000),
        })
        .collect::<Vec<_>>();
    report(
        "hydrate_turns turns=20 items=2000 text_bytes=960",
        measure(|| {
            black_box(hydrate_turns(&turns, &HydrationOptions::default()));
        }),
    );
}
