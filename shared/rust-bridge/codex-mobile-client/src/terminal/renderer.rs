//! Cross-platform terminal renderer surface owned by Rust.
//!
//! `TerminalRenderer` is the UniFFI object that platform code (Swift/Kotlin)
//! drives. It owns Ghostty-surface state (focus, occlusion, draw coalescing)
//! that needs to be identical on iOS and Android. The actual `ghostty_*` C
//! calls live in platform glue that implements `TerminalRendererBackend`.
//!
//! This file lands the foundation slice (focus, occlusion, draw cadence).
//! Later PRs widen `TerminalRendererBackend` with input/mouse/selection/config
//! methods — keep additions additive; never break existing call sites.
//!
//! Draw cadence: callers signal `notify_needs_draw()` whenever shared state
//! changes (e.g. new PTY bytes); a tokio tick task wakes ~every 16 ms, checks
//! the dirty flag, and asks the backend to redraw at most once per tick. This
//! replaces the iOS always-on `CADisplayLink` and the Android Choreographer
//! self-reschedule loop with on-demand redraws.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::config::{TerminalConfig, render_ghostty_conf};
use super::input::{TerminalKeyEvent, encode_text};
use super::links::{LinksCache, TerminalLink};
use super::osc::{
    OscParser, TerminalCellPosition, TerminalSemanticState, TerminalSemanticStateListener,
};
use super::selection::{TerminalCellMetrics, TerminalCellRange};
use super::session::TerminalError;
use crate::ffi::shared::shared_runtime;

/// Platform-implemented callback fired when the PTY stream emits a literal
/// BEL (0x07) byte in Ground state. The renderer fans one call out per
/// `feed_output` chunk that contains BEL(s); the platform applies its own
/// throttling on top (typical UX: 250 ms haptic cooldown).
#[uniffi::export(callback_interface)]
pub trait TerminalBellListener: Send + Sync {
    fn on_bell(&self);
}

/// Platform-implemented callback interface that maps Rust intent → Ghostty C
/// calls on the right thread.
///
/// Each method is invoked on the shared tokio runtime. Implementations are
/// expected to hop to their UI/graphics thread when they need a Ghostty C
/// call (the C surface is not thread-safe).
#[uniffi::export(callback_interface)]
pub trait TerminalRendererBackend: Send + Sync {
    /// Set keyboard focus on the surface. Maps to
    /// `ghostty_surface_set_focus` (and `ghostty_app_set_focus` for true
    /// app-wide focus).
    fn set_focus(&self, focused: bool);

    /// Update occlusion. Maps to `ghostty_surface_set_occlusion`.
    /// `occluded = true` when the app is backgrounded / surface is hidden,
    /// allowing Ghostty to pause animations and recover from any IO that
    /// blocked while invisible.
    fn set_occlusion(&self, occluded: bool);

    /// Ask the platform to advance its native terminal render loop once.
    /// Android routes draw work through this because its EGL context is
    /// owned by the view thread. UIKit Ghostty surfaces render on Ghostty's
    /// renderer thread, so iOS only drains the app mailbox on main.
    fn request_redraw(&self);

    /// Hot-apply the ghostty config at `path`. Platform runs
    /// the active-surface sequence
    /// (`ghostty_config_new` → `ghostty_config_load_file` →
    /// `ghostty_config_finalize` → `ghostty_surface_update_config` →
    /// `ghostty_config_free`) on the UI/graphics thread.
    fn apply_config_file(&self, path: String);

    /// Forward a translated key event to `ghostty_surface_key`.
    /// Platform owns the per-OS keycode translation table; we hand it the
    /// already-typed shared event.
    fn dispatch_key(&self, event: TerminalKeyEvent);

    /// Commit or preedit text. Empty `text` with `composing=true` finishes
    /// composition. Maps to `ghostty_surface_text` or
    /// `ghostty_surface_preedit`.
    fn dispatch_text(&self, text: String, composing: bool);

    /// Send already-encoded bytes (used for bracket-pasted text). Skips
    /// Ghostty's key encoder so the bracketed wrapper survives intact.
    fn dispatch_paste(&self, bytes: Vec<u8>);

    /// Read the currently-selected text from Ghostty's selection buffer.
    /// Returns `None` if no selection is active. Maps to
    /// `ghostty_surface_read_selection`.
    fn read_selection(&self) -> Option<String>;

    /// Read a viewport-relative cell range as plain text. Maps to
    /// `ghostty_surface_read_text` with a `GHOSTTY_POINT_VIEWPORT` selection.
    /// `start_row`/`end_row` are clamped by the platform to the viewport.
    fn read_text(
        &self,
        start_row: u32,
        start_col: u32,
        end_row: u32,
        end_col: u32,
    ) -> Option<String>;

    /// Current surface cell metrics (cell_w/h in px, cols/rows). Platform
    /// reads from the live Ghostty grid each call.
    fn cell_metrics(&self) -> super::selection::TerminalCellMetrics;

    /// Update or clear the painted selection overlay. The platform owns
    /// the highlight rectangle(s); we only push the range it should paint.
    fn set_selection_overlay(&self, range: Option<super::selection::TerminalCellRange>);
}

/// Cross-platform terminal renderer surface. Owns the dirty-flag draw
/// cadence and platform-visible lifecycle hooks; delegates actual Ghostty
/// calls to the platform-implemented [`TerminalRendererBackend`].
#[derive(uniffi::Object)]
pub struct TerminalRenderer {
    inner: Arc<RendererInner>,
}

struct RendererInner {
    backend: Mutex<Option<Arc<dyn TerminalRendererBackend>>>,
    dirty: AtomicBool,
    stopped: AtomicBool,
    rt: Arc<tokio::runtime::Runtime>,
    /// Directory to write rendered ghostty.conf files into. Platform sets
    /// this once at construction time (e.g. iOS Caches dir, Android cacheDir).
    config_dir: Mutex<Option<PathBuf>>,
    /// OSC 7/8/133/0/2 parser. The renderer tees PTY bytes here via
    /// [`TerminalRenderer::feed_output`] so platform code only has to
    /// forward bytes once.
    osc: Mutex<OscParser>,
    /// Shared semantic state observed by the OSC parser. The renderer
    /// hands snapshots out via [`TerminalRenderer::semantic_state`].
    semantic: Arc<Mutex<TerminalSemanticState>>,
    /// Listeners notified after every parser-driven state mutation.
    semantic_listeners: Arc<Mutex<Vec<Arc<dyn TerminalSemanticStateListener>>>>,
    /// Cached URL detection over the most recent viewport snapshot
    /// supplied by the platform. See [`super::links`].
    links: Mutex<LinksCache>,
    /// Listeners notified whenever `feed_output` observes one or more
    /// BEL bytes in `Ground` state.
    bell_listeners: Arc<Mutex<Vec<Arc<dyn TerminalBellListener>>>>,
}

#[uniffi::export]
impl TerminalRenderer {
    /// Create a renderer bound to `backend`. The renderer keeps the backend
    /// alive until [`TerminalRenderer::detach`] is called or the renderer is
    /// dropped.
    #[uniffi::constructor]
    pub fn new(backend: Box<dyn TerminalRendererBackend>) -> Self {
        let backend: Arc<dyn TerminalRendererBackend> = Arc::from(backend);
        let semantic = Arc::new(Mutex::new(TerminalSemanticState::default()));
        let semantic_listeners: Arc<Mutex<Vec<Arc<dyn TerminalSemanticStateListener>>>> =
            Arc::new(Mutex::new(Vec::new()));
        let osc = OscParser::new(semantic.clone(), semantic_listeners.clone());
        let inner = Arc::new(RendererInner {
            backend: Mutex::new(Some(backend)),
            dirty: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            rt: shared_runtime(),
            config_dir: Mutex::new(None),
            osc: Mutex::new(osc),
            semantic,
            semantic_listeners,
            links: Mutex::new(LinksCache::new()),
            bell_listeners: Arc::new(Mutex::new(Vec::new())),
        });
        spawn_tick_task(&inner);
        Self { inner }
    }

    /// Set the directory where `apply_config` writes the generated ghostty
    /// config file. iOS passes `<Caches>/litter/terminal`; Android passes
    /// `<cacheDir>/litter/terminal`. The directory is created on demand.
    pub fn set_config_dir(&self, path: String) {
        let mut guard = self.inner.config_dir.lock().unwrap();
        *guard = Some(PathBuf::from(path));
    }

    /// Render the provided config to a ghostty.conf file under the
    /// platform-supplied config dir, then ask the backend to hot-apply it
    /// through the embedded Ghostty surface. Returns
    /// [`TerminalError::Backend`] if the file couldn't be written or if
    /// `set_config_dir` was never called.
    pub fn apply_config(&self, config: TerminalConfig) -> Result<(), TerminalError> {
        let dir = self
            .inner
            .config_dir
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| TerminalError::Backend {
                detail: "set_config_dir not called".into(),
            })?;

        std::fs::create_dir_all(&dir).map_err(|err| TerminalError::Backend {
            detail: format!("create ghostty config dir: {err}"),
        })?;

        let epoch_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let path = dir.join(format!("ghostty-{epoch_ms}.conf"));
        let body = render_ghostty_conf(config);
        std::fs::write(&path, body).map_err(|err| TerminalError::Backend {
            detail: format!("write ghostty config: {err}"),
        })?;

        let backend = self.inner.current_backend().ok_or(TerminalError::Closed)?;
        backend.apply_config_file(path.to_string_lossy().into_owned());
        self.notify_needs_draw();
        Ok(())
    }

    /// Mark the renderer dirty; the next tick will request a redraw.
    pub fn notify_needs_draw(&self) {
        self.inner.dirty.store(true, Ordering::Release);
    }

    /// Forward focus state to the platform backend.
    pub fn set_focused(&self, focused: bool) {
        if let Some(backend) = self.inner.current_backend() {
            backend.set_focus(focused);
        }
    }

    /// Forward occlusion state to the platform backend.
    /// On un-occlude we also flag a redraw so the surface repaints cleanly.
    pub fn set_occluded(&self, occluded: bool) {
        if let Some(backend) = self.inner.current_backend() {
            backend.set_occlusion(occluded);
            if !occluded {
                self.notify_needs_draw();
            }
        }
    }

    /// Forward a translated key event to the platform backend. Schedules
    /// a redraw on the assumption Ghostty will produce output.
    pub fn send_key_event(&self, event: TerminalKeyEvent) {
        if let Some(backend) = self.inner.current_backend() {
            backend.dispatch_key(event);
            self.notify_needs_draw();
        }
    }

    /// Forward committed or preedit text. `composing=true` routes to
    /// `ghostty_surface_preedit`; the platform should pass an empty
    /// string with `composing=true` to clear composition state.
    pub fn send_text(&self, text: String, composing: bool) {
        if let Some(backend) = self.inner.current_backend() {
            backend.dispatch_text(text, composing);
            self.notify_needs_draw();
        }
    }

    /// Bracket-paste `text` and dispatch the wrapped bytes. The renderer
    /// applies the wrapping so iOS + Android share one paste convention.
    pub fn send_paste(&self, text: String) {
        if let Some(backend) = self.inner.current_backend() {
            backend.dispatch_paste(encode_text(&text, true));
            self.notify_needs_draw();
        }
    }

    /// Send already-encoded raw bytes straight to the PTY input direction,
    /// bypassing both the keyboard encoder and the bracketed-paste
    /// wrapper. Used by the on-screen accessory bar for control keys
    /// (Esc, Tab, Ctrl-C, arrow keys) so the shell sees them as if the
    /// user typed them, and never as a paste sequence.
    pub fn send_raw_bytes(&self, bytes: Vec<u8>) {
        if bytes.is_empty() {
            return;
        }
        if let Some(backend) = self.inner.current_backend() {
            backend.dispatch_paste(bytes);
            self.notify_needs_draw();
        }
    }

    /// Tee a chunk of PTY bytes through the OSC parser. The platform calls
    /// this with the same bytes it passes to `ghostty_surface_write`. The
    /// parser does not modify the byte stream — it only observes.
    ///
    /// Bytes are processed synchronously on the calling thread; the OSC
    /// mutex is short-held. Listeners (subscribed via
    /// [`TerminalRenderer::subscribe_semantic_state`]) are invoked
    /// synchronously after the chunk is parsed, so callers should batch
    /// the platform-side updates they trigger.
    ///
    /// If the chunk contains one or more BEL bytes in `Ground` state, the
    /// renderer also fires `on_bell` exactly once per non-empty BEL chunk
    /// to every subscriber. Platforms throttle the haptic / sound on top.
    pub fn feed_output(&self, bytes: Vec<u8>) {
        let bells = self.inner.osc.lock().unwrap().feed(&bytes);
        if bells > 0 {
            let listeners = self.inner.bell_listeners.lock().unwrap().clone();
            for listener in listeners {
                listener.on_bell();
            }
        }
    }

    /// Subscribe to bell events. Listeners are invoked synchronously from
    /// the byte-feed thread; the platform should hop to the UI thread
    /// before touching haptics / sound APIs.
    pub fn subscribe_bell(&self, listener: Box<dyn TerminalBellListener>) {
        let listener: Arc<dyn TerminalBellListener> = Arc::from(listener);
        self.inner.bell_listeners.lock().unwrap().push(listener);
    }

    /// Update the OSC parser's grid bounds used for cursor estimation
    /// (advances on CR/LF/wrap). Call from the platform after every
    /// successful resize.
    pub fn set_terminal_grid_size(&self, cols: u32, rows: u32) {
        self.inner.osc.lock().unwrap().set_grid_size(cols, rows);
    }

    /// Take a snapshot of the current semantic state (cwd / title /
    /// prompts / hyperlinks). Cheap clone — safe to call from the UI
    /// thread on every frame.
    pub fn semantic_state(&self) -> TerminalSemanticState {
        self.inner.semantic.lock().unwrap().clone()
    }

    /// Subscribe to semantic state changes. The listener is invoked
    /// synchronously from the byte-feed thread after every meaningful
    /// state mutation; do not block.
    pub fn subscribe_semantic_state(&self, listener: Box<dyn TerminalSemanticStateListener>) {
        let listener: Arc<dyn TerminalSemanticStateListener> = Arc::from(listener);
        self.inner.semantic_listeners.lock().unwrap().push(listener);
    }

    /// Push the current viewport text to the renderer so URL detection
    /// can run over it. `start_row` is the absolute row index of `rows[0]`
    /// (typically the top of the visible viewport). Recomputes the link
    /// cache; merges with OSC 8 hyperlinks (OSC 8 wins on overlap).
    /// Platform should call this on a debounce tied to
    /// `notify_needs_draw` (~200 ms).
    pub fn set_viewport_text(&self, start_row: u32, rows: Vec<String>) {
        let semantic = self.inner.semantic.lock().unwrap().clone();
        self.inner
            .links
            .lock()
            .unwrap()
            .update(start_row, &rows, &semantic.hyperlinks);
    }

    /// Return the currently cached URL set (plain-text + OSC 8 merged).
    /// Cheap clone — safe to call on every UI frame.
    pub fn links(&self) -> Vec<TerminalLink> {
        self.inner.links.lock().unwrap().snapshot()
    }

    /// Hit-test a cell position against the cached link set. Returns the
    /// first link whose range contains `position`. Platforms should
    /// translate tap coordinates to cell positions via their own grid
    /// metrics before calling.
    pub fn link_at(&self, row: u32, col: u32) -> Option<TerminalLink> {
        self.inner
            .links
            .lock()
            .unwrap()
            .link_at(TerminalCellPosition { row, col })
    }

    /// Pixel-coord → link lookup combining [`Self::hit_test`] with
    /// [`Self::link_at`], translating viewport-relative rows to absolute
    /// rows using the backend's `viewport_top`. Returns `None` if no
    /// backend is attached, the surface has zero-sized cells, or no link
    /// covers the cell under the touch point.
    pub fn link_at_point(&self, x_px: f32, y_px: f32) -> Option<TerminalLink> {
        let backend = self.inner.current_backend()?;
        let metrics = backend.cell_metrics();
        let viewport_pos = super::selection::hit_test_cell(metrics, x_px, y_px)?;
        let abs_row = metrics.viewport_top.saturating_add(viewport_pos.row);
        self.inner.links.lock().unwrap().link_at(TerminalCellPosition {
            row: abs_row,
            col: viewport_pos.col,
        })
    }

    /// Current surface cell metrics (cell width/height in pixels, grid
    /// dimensions). Returns `None` if no backend is attached. The platform
    /// uses this to compute PTY (cols, rows) from view pixel bounds
    /// instead of guessing from font size — keeps the PTY grid in lockstep
    /// with what Ghostty actually paints.
    pub fn cell_metrics(&self) -> Option<TerminalCellMetrics> {
        Some(self.inner.current_backend()?.cell_metrics())
    }

    /// Set the active selection range. Pushes the highlight overlay to
    /// the backend and remembers the range so [`Self::read_selection`]
    /// can pull the corresponding text.
    pub fn selection_set(&self, range: super::selection::TerminalCellRange) {
        if let Some(backend) = self.inner.current_backend() {
            backend.set_selection_overlay(Some(range));
        }
    }

    /// Clear the active selection.
    pub fn selection_clear(&self) {
        if let Some(backend) = self.inner.current_backend() {
            backend.set_selection_overlay(None);
        }
    }

    /// Convenience: select the entire visible viewport. Equivalent to
    /// "Select All" in the platform edit menu. Returns the range that was
    /// pushed, or `None` if no backend is attached or the surface reports
    /// zero rows/cols.
    pub fn selection_all(&self) -> Option<TerminalCellRange> {
        let backend = self.inner.current_backend()?;
        let metrics = backend.cell_metrics();
        if metrics.cols == 0 || metrics.rows == 0 {
            return None;
        }
        let range = TerminalCellRange {
            start: TerminalCellPosition { row: 0, col: 0 },
            end: TerminalCellPosition {
                row: metrics.rows.saturating_sub(1),
                col: metrics.cols.saturating_sub(1),
            },
            rectangle: false,
        };
        backend.set_selection_overlay(Some(range));
        Some(range)
    }

    /// Read the active selection text (whatever Ghostty's read-only
    /// selection API reports).
    pub fn read_selection(&self) -> Option<String> {
        self.inner.current_backend()?.read_selection()
    }

    /// Pixel-coord → cell-coord hit test using the backend's current
    /// `cell_metrics()`. Returns `None` if the backend reports zero-sized
    /// cells (surface not yet measured).
    pub fn hit_test(&self, x_px: f32, y_px: f32) -> Option<super::osc::TerminalCellPosition> {
        let backend = self.inner.current_backend()?;
        let metrics = backend.cell_metrics();
        super::selection::hit_test_cell(metrics, x_px, y_px)
    }

    /// Compute the word range under `pos`. Reads the surrounding line from
    /// the backend, runs unicode-segmentation word boundary math, and
    /// returns the resulting cell range. Returns `None` if the row is
    /// outside the viewport or the line read failed.
    pub fn word_range_at(
        &self,
        pos: super::osc::TerminalCellPosition,
    ) -> Option<super::selection::TerminalCellRange> {
        let backend = self.inner.current_backend()?;
        let metrics = backend.cell_metrics();
        let last_col = metrics.cols.saturating_sub(1);
        let line = backend.read_text(pos.row, 0, pos.row, last_col)?;
        let (start_col, end_col) = super::selection::word_columns_at(&line, pos.col);
        Some(super::selection::TerminalCellRange {
            start: super::osc::TerminalCellPosition {
                row: pos.row,
                col: start_col,
            },
            end: super::osc::TerminalCellPosition {
                row: pos.row,
                col: end_col,
            },
            rectangle: false,
        })
    }

    /// Compute the full-line range covering `pos`.
    pub fn line_range_at(
        &self,
        pos: super::osc::TerminalCellPosition,
    ) -> Option<super::selection::TerminalCellRange> {
        let backend = self.inner.current_backend()?;
        let metrics = backend.cell_metrics();
        let (start_col, end_col) = super::selection::line_columns(metrics);
        Some(super::selection::TerminalCellRange {
            start: super::osc::TerminalCellPosition {
                row: pos.row,
                col: start_col,
            },
            end: super::osc::TerminalCellPosition {
                row: pos.row,
                col: end_col,
            },
            rectangle: false,
        })
    }

    /// Detach from the backend and stop the tick task. Call from the
    /// platform when the surface is being torn down so the backing
    /// callback object can be released.
    pub fn detach(&self) {
        self.inner.stopped.store(true, Ordering::Release);
        let mut guard = self.inner.backend.lock().unwrap();
        *guard = None;
    }
}

/// Parameters for [`TerminalRenderer::send_selection_to_assistant`].
///
/// `thread_key` routes the resulting `start_turn` to the right server +
/// thread. `include_cwd` and `include_last_command` opt into pulling
/// extra context from the OSC 7 / OSC 133 semantic state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalSendToAssistantPayload {
    pub thread_key: crate::types::ThreadKey,
    pub include_cwd: bool,
    pub include_last_command: bool,
}

#[uniffi::export(async_runtime = "tokio")]
impl TerminalRenderer {
    /// Send the current terminal selection to the assistant as a turn
    /// input on `payload.thread_key`. Reads selection from Ghostty's
    /// read-only selection buffer, optionally prepends the current cwd
    /// (OSC 7) and last completed shell command (OSC 133), formats a
    /// fenced markdown body, and calls
    /// [`crate::ffi::AppStore::start_turn`].
    ///
    /// Returns [`crate::ffi::ClientError::InvalidParams`] if no
    /// selection is active or the selection is empty.
    pub async fn send_selection_to_assistant(
        &self,
        store: Arc<crate::ffi::AppStore>,
        payload: TerminalSendToAssistantPayload,
    ) -> Result<(), crate::ffi::ClientError> {
        let selection = self.read_selection().ok_or_else(|| {
            crate::ffi::ClientError::InvalidParams("no terminal selection active".into())
        })?;
        self.dispatch_assistant_turn(store, payload, &selection)
            .await
    }

    /// Variant of [`Self::send_selection_to_assistant`] that takes the
    /// selection text directly instead of reading it from Ghostty's
    /// selection buffer. Used by platform code when the painted selection
    /// overlay (PR-B-selection follow-up) isn't wired yet and the user
    /// drove selection through the system text-selection ActionMode /
    /// edit-menu instead.
    pub async fn send_text_to_assistant(
        &self,
        store: Arc<crate::ffi::AppStore>,
        payload: TerminalSendToAssistantPayload,
        selection: String,
    ) -> Result<(), crate::ffi::ClientError> {
        self.dispatch_assistant_turn(store, payload, &selection)
            .await
    }

    async fn dispatch_assistant_turn(
        &self,
        store: Arc<crate::ffi::AppStore>,
        payload: TerminalSendToAssistantPayload,
        selection: &str,
    ) -> Result<(), crate::ffi::ClientError> {
        let trimmed = selection.trim_end_matches('\n').to_string();
        if trimmed.is_empty() {
            return Err(crate::ffi::ClientError::InvalidParams(
                "empty terminal selection".into(),
            ));
        }
        let semantic = self.semantic_state();
        let cwd = if payload.include_cwd {
            semantic.cwd.clone()
        } else {
            None
        };
        let last_command = if payload.include_last_command {
            last_completed_command(&semantic.prompts)
        } else {
            None
        };
        let body = format_assistant_body(cwd.as_deref(), last_command.as_deref(), &trimmed);
        let request = crate::types::AppStartTurnRequest {
            thread_id: payload.thread_key.thread_id.clone(),
            input: vec![crate::types::AppUserInput::Text {
                text: body,
                text_elements: Vec::new(),
            }],
            approval_policy: None,
            sandbox_policy: None,
            model: None,
            service_tier: None,
            effort: None,
            output_schema: None,
        };
        store.start_turn(payload.thread_key, request).await
    }
}

/// Find the most recent completed prompt mark (one with `end_row`) and
/// return its `command_text` if non-empty. Empty command texts are
/// treated as "no command captured" because some shells emit OSC 133;A
/// without a `cmd=` payload.
fn last_completed_command(prompts: &[super::osc::TerminalPromptMark]) -> Option<String> {
    prompts
        .iter()
        .rev()
        .find(|m| m.end_row.is_some() && !m.command_text.is_empty())
        .map(|m| m.command_text.clone())
}

/// Build the markdown body sent to the assistant. Shape:
///
/// ```text
/// **Terminal selection** (cwd: `<cwd>`)
///
/// ```
/// $ <last_command>
/// <selection_text>
/// ```
/// ```
///
/// The `cwd:` prefix is omitted when `cwd` is `None`; the `$ <cmd>` line
/// is omitted when `last_command` is `None`. Selection is wrapped in a
/// fenced code block so the assistant sees it as preformatted output.
fn format_assistant_body(cwd: Option<&str>, last_command: Option<&str>, selection: &str) -> String {
    let mut out = String::with_capacity(selection.len() + 64);
    out.push_str("**Terminal selection**");
    if let Some(cwd) = cwd {
        out.push_str(" (cwd: `");
        out.push_str(cwd);
        out.push_str("`)");
    }
    out.push_str("\n\n```\n");
    if let Some(cmd) = last_command {
        out.push_str("$ ");
        out.push_str(cmd);
        out.push('\n');
    }
    out.push_str(selection);
    if !selection.ends_with('\n') {
        out.push('\n');
    }
    out.push_str("```\n");
    out
}

impl Drop for TerminalRenderer {
    fn drop(&mut self) {
        self.inner.stopped.store(true, Ordering::Release);
    }
}

impl RendererInner {
    fn current_backend(&self) -> Option<Arc<dyn TerminalRendererBackend>> {
        self.backend.lock().unwrap().as_ref().map(Arc::clone)
    }
}

/// Tick task: every 16 ms, if dirty, request one redraw. Driven via a
/// `Weak` so the task naturally exits when the renderer is dropped.
fn spawn_tick_task(inner: &Arc<RendererInner>) {
    let weak = Arc::downgrade(inner);
    let rt = inner.rt.clone();
    rt.spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(16));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            let Some(strong) = weak.upgrade() else { break };
            if strong.stopped.load(Ordering::Acquire) {
                break;
            }
            if strong.dirty.swap(false, Ordering::AcqRel)
                && let Some(backend) = strong.current_backend() {
                    drop(strong);
                    backend.request_redraw();
                }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    struct CountingBackend {
        focus_calls: AtomicUsize,
        occlusion_calls: AtomicUsize,
        redraw_calls: AtomicUsize,
        last_config_path: Mutex<Option<String>>,
    }

    impl CountingBackend {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                focus_calls: AtomicUsize::new(0),
                occlusion_calls: AtomicUsize::new(0),
                redraw_calls: AtomicUsize::new(0),
                last_config_path: Mutex::new(None),
            })
        }
    }

    impl TerminalRendererBackend for CountingBackend {
        fn set_focus(&self, _focused: bool) {
            self.focus_calls.fetch_add(1, Ordering::SeqCst);
        }
        fn set_occlusion(&self, _occluded: bool) {
            self.occlusion_calls.fetch_add(1, Ordering::SeqCst);
        }
        fn request_redraw(&self) {
            self.redraw_calls.fetch_add(1, Ordering::SeqCst);
        }
        fn apply_config_file(&self, path: String) {
            *self.last_config_path.lock().unwrap() = Some(path);
        }
        fn dispatch_key(&self, _event: TerminalKeyEvent) {}
        fn dispatch_text(&self, _text: String, _composing: bool) {}
        fn dispatch_paste(&self, _bytes: Vec<u8>) {}
        fn read_selection(&self) -> Option<String> {
            None
        }
        fn read_text(
            &self,
            _start_row: u32,
            _start_col: u32,
            _end_row: u32,
            _end_col: u32,
        ) -> Option<String> {
            None
        }
        fn cell_metrics(&self) -> super::super::selection::TerminalCellMetrics {
            super::super::selection::TerminalCellMetrics {
                cell_width_px: 10.0,
                cell_height_px: 20.0,
                cols: 80,
                rows: 24,
                viewport_top: 0,
            }
        }
        fn set_selection_overlay(
            &self,
            _range: Option<super::super::selection::TerminalCellRange>,
        ) {
        }
    }

    // The renderer constructor takes `Box<dyn TerminalRendererBackend>`, so
    // tests wrap a counting backend the same way platform bridges do.
    struct BackendAdapter(Arc<CountingBackend>);
    impl TerminalRendererBackend for BackendAdapter {
        fn set_focus(&self, f: bool) {
            self.0.set_focus(f);
        }
        fn set_occlusion(&self, o: bool) {
            self.0.set_occlusion(o);
        }
        fn request_redraw(&self) {
            self.0.request_redraw();
        }
        fn apply_config_file(&self, path: String) {
            self.0.apply_config_file(path);
        }
        fn dispatch_key(&self, event: TerminalKeyEvent) {
            self.0.dispatch_key(event);
        }
        fn dispatch_text(&self, text: String, composing: bool) {
            self.0.dispatch_text(text, composing);
        }
        fn dispatch_paste(&self, bytes: Vec<u8>) {
            self.0.dispatch_paste(bytes);
        }
        fn read_selection(&self) -> Option<String> {
            self.0.read_selection()
        }
        fn read_text(
            &self,
            start_row: u32,
            start_col: u32,
            end_row: u32,
            end_col: u32,
        ) -> Option<String> {
            self.0.read_text(start_row, start_col, end_row, end_col)
        }
        fn cell_metrics(&self) -> super::super::selection::TerminalCellMetrics {
            self.0.cell_metrics()
        }
        fn set_selection_overlay(&self, range: Option<super::super::selection::TerminalCellRange>) {
            self.0.set_selection_overlay(range);
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn focus_and_occlusion_are_forwarded() {
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));

        renderer.set_focused(true);
        renderer.set_occluded(true);
        renderer.set_occluded(false);

        assert_eq!(backend.focus_calls.load(Ordering::SeqCst), 1);
        assert_eq!(backend.occlusion_calls.load(Ordering::SeqCst), 2);
        // un-occlude flags a redraw; give the tick task one window to fire.
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert!(backend.redraw_calls.load(Ordering::SeqCst) >= 1);
        renderer.detach();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn dirty_burst_coalesces_into_few_redraws() {
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));

        // Simulate a 4 KB byte burst as many tiny chunks arriving fast.
        // Each chunk pokes notify_needs_draw; the tick task must coalesce.
        let start = std::time::Instant::now();
        for _ in 0..4096 {
            renderer.notify_needs_draw();
        }
        // Allow up to ~4 ticks (64 ms) to drain the dirty flag at most a
        // handful of times.
        tokio::time::sleep(Duration::from_millis(64)).await;
        let elapsed = start.elapsed();

        let redraws = backend.redraw_calls.load(Ordering::SeqCst);
        // 16 ms ticks across a 64 ms window: at most 4 redraws. Use ≤4
        // with the ceiling guarded against scheduler jitter.
        assert!(
            redraws <= 4,
            "expected ≤4 coalesced redraws in {elapsed:?}, got {redraws}"
        );
        renderer.detach();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn detach_stops_redraw_tick() {
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));
        renderer.detach();
        renderer.notify_needs_draw();
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(backend.redraw_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn apply_config_writes_file_and_invokes_backend() {
        use super::super::config::{TerminalConfig, TerminalCursorStyle, TerminalThemePreset};
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));

        let dir = std::env::temp_dir().join(format!("litter-renderer-test-{}", std::process::id()));
        renderer.set_config_dir(dir.to_string_lossy().into_owned());

        renderer
            .apply_config(TerminalConfig {
                theme: TerminalThemePreset::LitterDark,
                font_family: "SFMono-Regular".into(),
                font_size_pt: 14.0,
                cursor_style: TerminalCursorStyle::Block,
                cursor_blink: false,
                scrollback_lines: 5_000,
            })
            .expect("apply_config");

        let path = backend
            .last_config_path
            .lock()
            .unwrap()
            .clone()
            .expect("backend should have received config path");
        let contents = std::fs::read_to_string(&path).expect("conf body");
        assert!(contents.contains("font-size = 14"));
        assert!(contents.contains("cursor-style = block"));
        assert!(contents.contains("foreground = #00FF9C"));
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_dir(dir);
        renderer.detach();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn apply_config_without_set_config_dir_fails() {
        use super::super::config::{TerminalConfig, TerminalCursorStyle, TerminalThemePreset};
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));
        let err = renderer
            .apply_config(TerminalConfig {
                theme: TerminalThemePreset::LitterDark,
                font_family: "x".into(),
                font_size_pt: 13.0,
                cursor_style: TerminalCursorStyle::Bar,
                cursor_blink: true,
                scrollback_lines: 1000,
            })
            .expect_err("apply_config should fail without dir");
        assert!(matches!(err, TerminalError::Backend { .. }));
        renderer.detach();
    }

    #[test]
    fn format_assistant_body_with_cwd_and_command() {
        let body = format_assistant_body(Some("/tmp/work"), Some("ls -la"), "total 8\ndrwxr-xr-x");
        assert_eq!(
            body,
            "**Terminal selection** (cwd: `/tmp/work`)\n\n```\n$ ls -la\ntotal 8\ndrwxr-xr-x\n```\n",
        );
    }

    #[test]
    fn format_assistant_body_minimal() {
        let body = format_assistant_body(None, None, "hello");
        assert_eq!(body, "**Terminal selection**\n\n```\nhello\n```\n");
    }

    #[test]
    fn format_assistant_body_preserves_trailing_newline() {
        let body = format_assistant_body(None, None, "line1\nline2\n");
        assert_eq!(body, "**Terminal selection**\n\n```\nline1\nline2\n```\n");
    }

    #[test]
    fn last_completed_command_picks_latest_with_text() {
        use super::super::osc::TerminalPromptMark;
        let prompts = vec![
            TerminalPromptMark {
                start_row: Some(0),
                command_row: Some(0),
                output_row: Some(1),
                end_row: Some(2),
                exit_code: Some(0),
                command_text: "pwd".into(),
            },
            TerminalPromptMark {
                start_row: Some(3),
                command_row: Some(3),
                output_row: Some(4),
                end_row: Some(5),
                exit_code: Some(127),
                command_text: "gcc bug.c".into(),
            },
        ];
        assert_eq!(
            last_completed_command(&prompts).as_deref(),
            Some("gcc bug.c"),
        );
    }

    #[test]
    fn last_completed_command_skips_in_flight_marks() {
        use super::super::osc::TerminalPromptMark;
        let prompts = vec![
            TerminalPromptMark {
                start_row: Some(0),
                command_row: Some(0),
                output_row: Some(1),
                end_row: Some(2),
                exit_code: Some(0),
                command_text: "ls".into(),
            },
            // In-flight mark (no end_row) — must be skipped.
            TerminalPromptMark {
                start_row: Some(3),
                command_row: Some(3),
                output_row: Some(4),
                end_row: None,
                exit_code: None,
                command_text: "find /".into(),
            },
        ];
        assert_eq!(last_completed_command(&prompts).as_deref(), Some("ls"));
    }

    #[test]
    fn last_completed_command_returns_none_when_no_marks() {
        assert!(last_completed_command(&[]).is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cell_metrics_passes_through_backend() {
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));
        let metrics = renderer.cell_metrics().expect("metrics");
        assert_eq!(metrics.cell_width_px, 10.0);
        assert_eq!(metrics.cell_height_px, 20.0);
        assert_eq!(metrics.cols, 80);
        assert_eq!(metrics.rows, 24);
        renderer.detach();
        assert!(renderer.cell_metrics().is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn selection_all_pushes_full_viewport_range() {
        struct OverlayCapturing {
            last: Mutex<Option<Option<super::super::selection::TerminalCellRange>>>,
        }
        impl TerminalRendererBackend for OverlayCapturing {
            fn set_focus(&self, _: bool) {}
            fn set_occlusion(&self, _: bool) {}
            fn request_redraw(&self) {}
            fn apply_config_file(&self, _: String) {}
            fn dispatch_key(&self, _: TerminalKeyEvent) {}
            fn dispatch_text(&self, _: String, _: bool) {}
            fn dispatch_paste(&self, _: Vec<u8>) {}
            fn read_selection(&self) -> Option<String> {
                None
            }
            fn read_text(&self, _: u32, _: u32, _: u32, _: u32) -> Option<String> {
                None
            }
            fn cell_metrics(&self) -> super::super::selection::TerminalCellMetrics {
                super::super::selection::TerminalCellMetrics {
                    cell_width_px: 10.0,
                    cell_height_px: 20.0,
                    cols: 80,
                    rows: 24,
                    viewport_top: 0,
                }
            }
            fn set_selection_overlay(
                &self,
                range: Option<super::super::selection::TerminalCellRange>,
            ) {
                *self.last.lock().unwrap() = Some(range);
            }
        }
        let backend = Arc::new(OverlayCapturing {
            last: Mutex::new(None),
        });
        struct Adapter(Arc<OverlayCapturing>);
        impl TerminalRendererBackend for Adapter {
            fn set_focus(&self, f: bool) {
                self.0.set_focus(f);
            }
            fn set_occlusion(&self, o: bool) {
                self.0.set_occlusion(o);
            }
            fn request_redraw(&self) {
                self.0.request_redraw();
            }
            fn apply_config_file(&self, p: String) {
                self.0.apply_config_file(p);
            }
            fn dispatch_key(&self, e: TerminalKeyEvent) {
                self.0.dispatch_key(e);
            }
            fn dispatch_text(&self, t: String, c: bool) {
                self.0.dispatch_text(t, c);
            }
            fn dispatch_paste(&self, b: Vec<u8>) {
                self.0.dispatch_paste(b);
            }
            fn read_selection(&self) -> Option<String> {
                self.0.read_selection()
            }
            fn read_text(&self, a: u32, b: u32, c: u32, d: u32) -> Option<String> {
                self.0.read_text(a, b, c, d)
            }
            fn cell_metrics(&self) -> super::super::selection::TerminalCellMetrics {
                self.0.cell_metrics()
            }
            fn set_selection_overlay(
                &self,
                r: Option<super::super::selection::TerminalCellRange>,
            ) {
                self.0.set_selection_overlay(r);
            }
        }
        let renderer = TerminalRenderer::new(Box::new(Adapter(backend.clone())));
        let range = renderer.selection_all().expect("range");
        use super::super::osc::TerminalCellPosition;
        assert_eq!(range.start, TerminalCellPosition { row: 0, col: 0 });
        assert_eq!(range.end, TerminalCellPosition { row: 23, col: 79 });
        assert_eq!(
            backend.last.lock().unwrap().as_ref().unwrap().unwrap(),
            range
        );
        renderer.selection_clear();
        assert!(backend.last.lock().unwrap().as_ref().unwrap().is_none());
        renderer.detach();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn bell_listener_fires_on_ground_bel() {
        struct CountingBell {
            count: AtomicUsize,
        }
        impl TerminalBellListener for CountingBell {
            fn on_bell(&self) {
                self.count.fetch_add(1, Ordering::SeqCst);
            }
        }
        let backend = CountingBackend::new();
        let renderer = TerminalRenderer::new(Box::new(BackendAdapter(backend.clone())));
        let listener = Arc::new(CountingBell {
            count: AtomicUsize::new(0),
        });
        struct Forward(Arc<CountingBell>);
        impl TerminalBellListener for Forward {
            fn on_bell(&self) {
                self.0.on_bell();
            }
        }
        renderer.subscribe_bell(Box::new(Forward(listener.clone())));

        // One BEL → one fire.
        renderer.feed_output(b"hello\x07".to_vec());
        assert_eq!(listener.count.load(Ordering::SeqCst), 1);

        // OSC-terminator BEL doesn't fire.
        renderer.feed_output(b"\x1b]7;file://h/tmp\x07".to_vec());
        assert_eq!(listener.count.load(Ordering::SeqCst), 1);

        // Two BELs in the same chunk coalesce to a single fan-out
        // (platform applies its own haptic throttle on top, but the
        // renderer pre-collapses bursts so a "ding flood" from a shell
        // script doesn't translate to hundreds of UI events).
        renderer.feed_output(b"\x07\x07".to_vec());
        assert_eq!(listener.count.load(Ordering::SeqCst), 2);
        renderer.detach();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn link_at_point_uses_hit_test_and_viewport_top() {
        struct WithViewport;
        impl TerminalRendererBackend for WithViewport {
            fn set_focus(&self, _: bool) {}
            fn set_occlusion(&self, _: bool) {}
            fn request_redraw(&self) {}
            fn apply_config_file(&self, _: String) {}
            fn dispatch_key(&self, _: TerminalKeyEvent) {}
            fn dispatch_text(&self, _: String, _: bool) {}
            fn dispatch_paste(&self, _: Vec<u8>) {}
            fn read_selection(&self) -> Option<String> {
                None
            }
            fn read_text(&self, _: u32, _: u32, _: u32, _: u32) -> Option<String> {
                None
            }
            fn cell_metrics(&self) -> super::super::selection::TerminalCellMetrics {
                super::super::selection::TerminalCellMetrics {
                    cell_width_px: 10.0,
                    cell_height_px: 20.0,
                    cols: 80,
                    rows: 24,
                    viewport_top: 100,
                }
            }
            fn set_selection_overlay(
                &self,
                _: Option<super::super::selection::TerminalCellRange>,
            ) {
            }
        }
        let renderer = TerminalRenderer::new(Box::new(WithViewport));
        // Seed link cache: a URL at absolute row 102, cols 4..23.
        renderer.set_viewport_text(
            100,
            vec![
                "row 100".to_string(),
                "row 101".to_string(),
                "see https://example.com here".to_string(),
            ],
        );
        // Pixel (60, 50) → cell (col 6, row 2 viewport-relative) →
        // absolute row 102, col 6 — inside the URL.
        let link = renderer.link_at_point(60.0, 50.0).expect("link");
        assert_eq!(link.url, "https://example.com");

        // Pixel outside the URL columns returns None.
        assert!(renderer.link_at_point(0.0, 50.0).is_none());
        renderer.detach();
    }
}
