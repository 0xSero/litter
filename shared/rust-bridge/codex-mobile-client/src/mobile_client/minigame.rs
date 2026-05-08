use codex_app_server_protocol as upstream;
use tracing::{info, warn};

use crate::mobile_client::{WidgetFinalizedPayload, WidgetWaiter};
use crate::types::server_requests::{
    reasoning_effort_into_upstream, service_tier_into_upstream_string,
};
use crate::types::{ReasoningEffort, ServiceTier};
use crate::widget_guidelines::show_widget_tool_spec;

const MINIGAME_TIMEOUT_SECS: u64 = 30;
const MINIGAME_CONTEXT_TRUNCATE_CHARS: usize = 600;
const MINIGAME_MODEL: &str = "gpt-5.3-codex-spark";

pub struct MinigameRequest {
    pub server_id: String,
    pub parent_thread_id: String,
    pub last_user_message: Option<String>,
    pub last_assistant_message: Option<String>,
}

pub struct MinigameResult {
    pub ephemeral_thread_id: String,
    pub widget_html: String,
    pub title: String,
    pub width: f64,
    pub height: f64,
}

/// Available game archetypes. We pick one per call so the model stops
/// defaulting to endless-runner for everything.
const ARCHETYPES: &[(&str, &str)] = &[
    (
        "tap-to-flap",
        "A bird/rocket/fish flaps upward with each tap and falls under gravity. \
         It must thread through scrolling vertical gaps. Score = gaps cleared.",
    ),
    (
        "top-down dodger",
        "Camera looks down from above. The protagonist drifts at the bottom; \
         drag finger horizontally to steer. Hazards drop from the top in waves \
         that increase in density. Score = seconds survived.",
    ),
    (
        "slingshot",
        "A draggable projectile at the bottom; pull-back-and-release fires it \
         on a parabolic arc to hit a target zone. Three shots per round. \
         Visible aim trajectory while dragging. Score = targets hit.",
    ),
    (
        "rhythm tap",
        "Markers slide along a horizontal lane toward a fixed hit zone at the \
         left edge. Tap when each marker overlaps the zone. Tempo accelerates. \
         Visual feedback: ring pulse on perfect, screen-shake on miss.",
    ),
    (
        "catch-and-avoid",
        "A paddle/bowl at the bottom moves horizontally with finger drag. \
         Good things to catch and bad things to dodge fall from the top in \
         parallel streams. Score = goods caught minus bads caught.",
    ),
    (
        "vertical platformer",
        "Doodle-Jump style: protagonist auto-bounces upward off horizontal \
         platforms; tilt-or-tap chooses left/right drift. Camera scrolls up. \
         Score = altitude reached. Falling off the bottom ends the round.",
    ),
    (
        "tap-to-orbit",
        "A small object whirls around a central anchor on a fixed-radius leash. \
         Tap to flip its rotation direction. Avoid orbiting walls/spikes that \
         appear and rotate. Score = laps survived.",
    ),
    (
        "two-finger juggle",
        "Two balls bounce on the left and right halves. Tap each side to nudge \
         that side's ball back up before it falls. Independent timing. Score \
         = total bounces sustained.",
    ),
    (
        "endless runner",
        "Side-view: protagonist auto-runs left-to-right; tap to jump over and \
         long-press to duck under scrolling obstacles. Score ticks up. Speed \
         increases over time.",
    ),
    (
        "asteroid drift",
        "Top-down: protagonist sits centred; a single tap thrusts in the last \
         drag direction. Asteroids drift across the field; rebound off them \
         to score combo multipliers. Avoid the spiked ones.",
    ),
    (
        "wave-rider",
        "Side-view: protagonist surfs on a parametric sine wave that scrolls \
         right-to-left. Hold the screen to ride the wave's crests; release to \
         fall through troughs. Threshold lines spawn rewards/hazards on \
         crests vs troughs.",
    ),
    (
        "colour-match",
        "Three lanes scroll downward, each carrying a coloured token. The \
         protagonist sits at the bottom and cycles through colours on tap. \
         Catch tokens whose colour matches yours; ignore mismatches.",
    ),
];

fn choose_minigame_server_id(
    requested_server_id: &str,
    mut local_server_ids: Vec<String>,
) -> Option<String> {
    if local_server_ids
        .iter()
        .any(|server_id| server_id == requested_server_id)
    {
        return Some(requested_server_id.to_string());
    }
    if local_server_ids
        .iter()
        .any(|server_id| server_id == "local")
    {
        return Some("local".to_string());
    }

    local_server_ids.sort();
    local_server_ids.dedup();
    local_server_ids.into_iter().next()
}

fn resolve_minigame_server_id(
    client: &crate::MobileClient,
    requested_server_id: &str,
) -> Result<String, String> {
    let local_server_ids = client
        .sessions_read()
        .values()
        .filter(|session| session.config().is_local)
        .map(|session| session.config().server_id.clone())
        .collect::<Vec<_>>();

    choose_minigame_server_id(requested_server_id, local_server_ids)
        .ok_or_else(|| "minigame generation requires a connected local server".to_string())
}

/// Pick one archetype non-deterministically so consecutive minigames vary.
fn pick_archetype() -> &'static (&'static str, &'static str) {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as usize)
        .unwrap_or(0);
    // Mix the nanosecond reading with the address of a stack local to add
    // entropy across processes that boot at the same wall-clock instant.
    let local = 0u8;
    let addr = (&local as *const u8) as usize;
    let mixed = nanos.wrapping_add(addr.wrapping_mul(2654435761));
    &ARCHETYPES[mixed % ARCHETYPES.len()]
}

/// Build the developer instructions for the minigame thread.
///
/// Optimised for low TTFT on `gpt-5.3-codex-spark` with Low effort:
/// every redundant sentence costs prompt-processing time.
pub(crate) fn build_developer_instructions(
    last_user: Option<&str>,
    last_assistant: Option<&str>,
) -> String {
    let (archetype_name, archetype_brief) = *pick_archetype();
    let truncate = |s: &str| -> String {
        if s.chars().count() <= MINIGAME_CONTEXT_TRUNCATE_CHARS {
            s.to_string()
        } else {
            let truncated: String = s.chars().take(MINIGAME_CONTEXT_TRUNCATE_CHARS).collect();
            format!("{truncated}…")
        }
    };

    let user_ctx = last_user
        .map(|s| truncate(s))
        .unwrap_or_else(|| "(none)".to_string());
    let assistant_ctx = last_assistant
        .map(|s| truncate(s))
        .unwrap_or_else(|| "(none, still generating)".to_string());

    format!(
        r#"Output exactly ONE `show_widget` tool call. No prose, no follow-up.

Build a tiny touch-arcade game (Chrome dino vibe) that fits in a 360x320
WebView panel. ONE <canvas>, requestAnimationFrame loop with delta-time,
pointerdown for input. Static HTML/CSS layouts are forbidden — if a
freeze-frame looks like an app instead of a game, start over.

ARCHETYPE: {archetype_name}
{archetype_brief}
Build exactly that. Do not substitute.

THEMING — mine the conversation below hard. Use specific nouns, errors,
filenames, jargon as the protagonist / hazards / score-unit / game-over
text. Be irreverent or slightly creepy; the user opted in. No emails,
keys, tokens, or private file contents.

Required: a "Tap to start" pre-screen, score that ticks up, "Game over —
tap to retry" that resets in-place (no reload), and visible juice (pick
two: gravity, particle bursts, screen-shake on hit, squash/stretch,
parallax). Use CSS vars for colour: `--color-background-primary` (bg),
`--color-text-primary`, `--color-info`, `--color-success`,
`--color-warning`, `--color-danger`. Cache them via `getComputedStyle`.
Never hardcode `#000`/`#fff`. No audio. No CDN unless you genuinely
need it (cdnjs/esm.sh/jsdelivr/unpkg only).

Forbidden APIs (no-op in this view): window.sendPrompt, saveAppState,
loadAppState, structuredResponse.

Output:
- `i_have_seen_read_me`: true
- `app_id`: `mg-<theme>-<archetype>` kebab slug (e.g. `mg-segfault-orbit`)
- `title`: 1-3 words, themed
- `widget_code`: HTML fragment (no DOCTYPE/html/head/body), order:
  short <style> → <canvas> → <script>

USER: {user_ctx}
ASSISTANT: {assistant_ctx}"#
    )
}

pub(crate) async fn run_minigame(
    client: &crate::MobileClient,
    request: MinigameRequest,
) -> Result<MinigameResult, String> {
    let requested_server_id = &request.server_id;
    let server_id = resolve_minigame_server_id(client, requested_server_id)?;
    let parent_thread_id = &request.parent_thread_id;
    if server_id != *requested_server_id {
        info!(
            "minigame: routing ephemeral thread to local server {} instead of parent server {}",
            server_id, requested_server_id
        );
    }

    // Use the trimmed minigame-specific prompt directly. We do NOT prepend
    // GENERATIVE_UI_PREAMBLE here — its general "use show_widget when the
    // user asks for a game/dashboard/etc." advice is irrelevant to this
    // ephemeral thread (where the only registered tool IS show_widget) and
    // every redundant input token slows TTFT.
    let developer_instructions = build_developer_instructions(
        request.last_user_message.as_deref(),
        request.last_assistant_message.as_deref(),
    );

    let app_tool = show_widget_tool_spec();
    let input_schema: serde_json::Value = serde_json::from_str(&app_tool.input_schema_json)
        .map_err(|e| format!("parse show_widget input schema: {e}"))?;
    let dynamic_tools = vec![upstream::DynamicToolSpec {
        name: app_tool.name,
        description: app_tool.description,
        input_schema,
        namespace: None,
        defer_loading: app_tool.defer_loading,
    }];

    // 1. Start ephemeral thread
    let start_params = upstream::ThreadStartParams {
        model: Some(MINIGAME_MODEL.to_string()),
        model_provider: None,
        // ThreadStartParams.service_tier is Option<Option<ServiceTier>> (double-option wire format)
        service_tier: Some(Some(service_tier_into_upstream_string(ServiceTier::Fast))),
        cwd: None,
        approval_policy: None,
        approvals_reviewer: None,
        sandbox: None,
        permissions: None,
        config: None,
        service_name: None,
        base_instructions: None,
        developer_instructions: Some(developer_instructions),
        personality: None,
        ephemeral: Some(true),
        session_start_source: None,
        thread_source: None,
        environments: None,
        dynamic_tools: Some(dynamic_tools),
        mock_experimental_field: None,
        experimental_raw_events: false,
        persist_extended_history: false,
    };

    let thread_response: upstream::ThreadStartResponse = client
        .request_typed_for_server(
            &server_id,
            upstream::ClientRequest::ThreadStart {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: start_params,
            },
        )
        .await
        .map_err(|e| format!("thread/start failed: {e}"))?;

    let ephemeral_thread_id = thread_response.thread.id.clone();
    info!(
        "minigame: started ephemeral thread {} for parent {}",
        ephemeral_thread_id, parent_thread_id
    );

    // 2. Register WidgetWaiter keyed by ephemeral thread id
    let (waiter_tx, waiter_rx) = tokio::sync::oneshot::channel::<WidgetFinalizedPayload>();
    {
        let mut guard = client
            .widget_waiters
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.insert(
            ephemeral_thread_id.clone(),
            WidgetWaiter { sender: waiter_tx },
        );
    }

    // 3. Run one turn
    let turn_params = upstream::TurnStartParams {
        thread_id: ephemeral_thread_id.clone(),
        input: vec![upstream::UserInput::Text {
            text: "Generate the minigame now.".to_string(),
            text_elements: Vec::new(),
        }],
        responsesapi_client_metadata: None,
        cwd: None,
        approval_policy: None,
        approvals_reviewer: None,
        sandbox_policy: None,
        environments: None,
        permissions: None,
        model: Some(MINIGAME_MODEL.to_string()),
        // Upstream TurnStartParams.service_tier is Option<Option<CoreServiceTier>>
        service_tier: Some(Some(service_tier_into_upstream_string(ServiceTier::Fast))),
        effort: Some(reasoning_effort_into_upstream(ReasoningEffort::Low)),
        summary: None,
        personality: None,
        output_schema: None,
        collaboration_mode: None,
    };

    if let Err(e) = client
        .request_typed_for_server::<upstream::TurnStartResponse>(
            &server_id,
            upstream::ClientRequest::TurnStart {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: turn_params,
            },
        )
        .await
    {
        // Clean up the waiter on failure
        let _ = client
            .widget_waiters
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&ephemeral_thread_id);
        cleanup_ephemeral_thread(client, &server_id, &ephemeral_thread_id).await;
        return Err(format!("turn/start failed: {e}"));
    }

    // 4. Race waiter against 30s timeout
    let wait_outcome = tokio::time::timeout(
        std::time::Duration::from_secs(MINIGAME_TIMEOUT_SECS),
        waiter_rx,
    )
    .await;

    // 5. Best-effort cancel ephemeral thread
    cleanup_ephemeral_thread(client, &server_id, &ephemeral_thread_id).await;

    let payload = match wait_outcome {
        Ok(Ok(payload)) => payload,
        Ok(Err(_)) => {
            return Err("widget waiter channel closed without a result".to_string());
        }
        Err(_) => {
            // Remove waiter that was never fulfilled
            let _ = client
                .widget_waiters
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&ephemeral_thread_id);
            return Err(format!(
                "minigame generation timed out after {MINIGAME_TIMEOUT_SECS}s"
            ));
        }
    };

    // Note: minigames are intentionally NOT saved as widgets in the SavedApps
    // store, and they are not associated with the parent thread in any way.
    // The waiter path skips `auto_upsert_saved_app` (see
    // `try_fulfill_widget_waiter` in `dynamic_tools.rs`), and the ephemeral
    // thread is torn down above. The widget HTML lives only for the lifetime
    // of the overlay on the platform side.
    let _ = parent_thread_id; // explicitly unused after this point

    Ok(MinigameResult {
        ephemeral_thread_id,
        widget_html: payload.widget_html,
        title: payload.title,
        width: payload.width,
        height: payload.height,
    })
}

async fn cleanup_ephemeral_thread(client: &crate::MobileClient, server_id: &str, thread_id: &str) {
    let archive_result: Result<upstream::ThreadArchiveResponse, _> = client
        .request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadArchive {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: upstream::ThreadArchiveParams {
                    thread_id: thread_id.to_string(),
                },
            },
        )
        .await;
    if let Err(e) = archive_result {
        warn!("minigame: thread/archive failed for thread {thread_id}: {e} (ignored)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_developer_instructions_includes_context() {
        let instructions = build_developer_instructions(
            Some("How do I sort a list in Python?"),
            Some("You can use list.sort() or sorted()."),
        );
        assert!(instructions.contains("How do I sort a list in Python?"));
        assert!(instructions.contains("You can use list.sort()"));
    }

    #[test]
    fn build_developer_instructions_none_context() {
        let instructions = build_developer_instructions(None, None);
        assert!(instructions.contains("USER: (none)"));
        assert!(instructions.contains("ASSISTANT: (none, still generating)"));
    }

    #[test]
    fn build_developer_instructions_truncates_long_messages() {
        let long_msg = "a".repeat(700);
        let instructions = build_developer_instructions(Some(&long_msg), None);
        // The user context should be truncated to 600 chars + ellipsis
        let user_line_start = instructions.find("USER: ").expect("USER: label");
        let user_section = &instructions[user_line_start + 6..];
        let user_end = user_section.find('\n').unwrap_or(user_section.len());
        let user_ctx = &user_section[..user_end];
        // 600 'a' chars + ellipsis character (3 bytes) = more than 600 but the char count is 601
        assert!(user_ctx.chars().count() <= MINIGAME_CONTEXT_TRUNCATE_CHARS + 2);
        assert!(user_ctx.ends_with('…'));
    }

    #[test]
    fn build_developer_instructions_contains_required_directives() {
        let instructions = build_developer_instructions(Some("test"), None);
        assert!(instructions.contains("show_widget"));
        assert!(instructions.contains("i_have_seen_read_me: true"));
        assert!(instructions.contains("mg-"));
        assert!(instructions.contains("window.sendPrompt"));
    }

    #[test]
    fn choose_minigame_server_keeps_requested_when_local() {
        let chosen = choose_minigame_server_id(
            "device-local",
            vec!["local".to_string(), "device-local".to_string()],
        );
        assert_eq!(chosen.as_deref(), Some("device-local"));
    }

    #[test]
    fn choose_minigame_server_prefers_canonical_local_for_remote_parent() {
        let chosen = choose_minigame_server_id(
            "remote",
            vec!["device-local".to_string(), "local".to_string()],
        );
        assert_eq!(chosen.as_deref(), Some("local"));
    }

    #[test]
    fn choose_minigame_server_returns_none_without_local_session() {
        assert_eq!(choose_minigame_server_id("remote", Vec::new()), None);
    }
}
