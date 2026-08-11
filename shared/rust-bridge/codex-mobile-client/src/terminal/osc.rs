//! OSC (Operating System Command) parser for terminal semantic shell
//! integration.
//!
//! Tees the raw PTY byte stream before it reaches Ghostty and extracts:
//!   - OSC 7  (`file://host/path`)         → current working directory
//!   - OSC 8  (`params;url`)               → hyperlinks
//!   - OSC 133 (`A` / `B` / `C` / `D;<exit>`) → prompt / command / output / end marks
//!   - OSC 0  / OSC 2 (`title`)            → window title
//!
//! The parser is observation-only — it never modifies the byte stream, only
//! emits semantic events. Bytes are passed through to Ghostty by the caller
//! independently.
//!
//! Cursor tracking: the parser maintains a running grid estimate (row, col)
//! advanced from CR/LF/Tab/printable bytes. SGR (`ESC[ ... m`) and other CSI
//! sequences are recognized and skipped without advancing the cursor.
//! Hyperlink anchors are recorded at the grid position seen by the parser
//! when the start/end OSC 8 sequence arrives. The grid wrap column is set
//! by [`OscParser::set_grid_size`] (caller passes terminal cols/rows after
//! resize); if never set, defaults to 80×24 which is forgiving for tests.
//!
//! Hyperlink robustness across resize: callers should re-snapshot
//! [`TerminalSemanticState::hyperlinks`] after each resize and treat row
//! positions as best-effort. The parser does not attempt to re-flow
//! historical anchors when the terminal is resized — that is intentional
//! per the plan (anchor by byte offset; resize invalidates row math but
//! the URL itself stays usable).

use std::sync::Arc;
use std::sync::Mutex;

/// A cell position in the terminal grid. Row 0 is the top of the
/// scrollback ring as observed by the parser since session start; for
/// short-lived sessions it lines up with the visible viewport.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TerminalCellPosition {
    pub row: u32,
    pub col: u32,
}

/// A completed (or in-flight) prompt region produced by an OSC 133-aware
/// shell. Fields are set as the corresponding mark arrives:
///   - `start_row` from OSC 133;A
///   - `command_row` from OSC 133;B
///   - `output_row` from OSC 133;C
///   - `end_row` + `exit_code` from OSC 133;D;<exit>
///
/// A mark is "completed" once `end_row.is_some()`. `command_text` is the
/// shell-supplied command if the shell included it (some shells emit
/// `OSC 133;A;cmd=...`) — empty if not.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalPromptMark {
    pub start_row: Option<u32>,
    pub command_row: Option<u32>,
    pub output_row: Option<u32>,
    pub end_row: Option<u32>,
    pub exit_code: Option<i32>,
    pub command_text: String,
}

/// A hyperlink emitted by OSC 8. `id` is the optional `id=` parameter the
/// shell used to group multi-cell hyperlinks; empty if absent.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalHyperlink {
    pub start: TerminalCellPosition,
    pub end: TerminalCellPosition,
    pub url: String,
    pub id: String,
}

/// Snapshot of all semantic state extracted from the byte stream so far.
/// Returned by [`crate::terminal::TerminalRenderer::semantic_state`] as a
/// cheap clone; safe to hold and inspect from the platform side without a
/// lock.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TerminalSemanticState {
    /// Last cwd announced by the shell via OSC 7. `None` if the shell
    /// hasn't emitted one yet.
    pub cwd: Option<String>,
    /// Last window title from OSC 0 / OSC 2.
    pub title: Option<String>,
    /// All prompt marks seen, in arrival order. Callers should iterate in
    /// reverse to find the most recent completed prompt.
    pub prompts: Vec<TerminalPromptMark>,
    /// All completed hyperlinks (OSC 8 pairs). In-flight hyperlinks (start
    /// without matching end) are not exposed.
    pub hyperlinks: Vec<TerminalHyperlink>,
}

/// Platform-implemented callback invoked when the semantic state changes.
/// Callers should batch UI updates if invoked rapidly (the parser emits a
/// notification for every meaningful state change).
#[uniffi::export(callback_interface)]
pub trait TerminalSemanticStateListener: Send + Sync {
    fn on_state_changed(&self, state: TerminalSemanticState);
}

/// Maximum payload bytes we accept inside an OSC sequence. Anything longer
/// is dropped silently and the parser returns to Ground. 16 KiB is enough
/// for any reasonable hyperlink URL or shell prompt annotation.
const MAX_OSC_PAYLOAD: usize = 16 * 1024;

/// Default grid size used until the caller invokes
/// [`OscParser::set_grid_size`].
const DEFAULT_COLS: u32 = 80;
const DEFAULT_ROWS: u32 = 24;

/// Tab stop width used by the cursor estimator. Most terminals use 8.
const TABSTOP: u32 = 8;

/// Internal parser state machine. Bytes are fed via [`OscParser::feed`]
/// (one chunk at a time). The parser owns the [`TerminalSemanticState`]
/// behind a mutex and notifies the registered listeners whenever a parse
/// event mutates that state.
pub(crate) struct OscParser {
    state: ParserState,
    /// Active OSC payload being accumulated. Cleared at every dispatch.
    payload: Vec<u8>,
    /// Whether the payload has overflowed `MAX_OSC_PAYLOAD`; in that case
    /// we keep scanning until terminator but drop the contents.
    payload_overflow: bool,
    /// Grid bounds for the cursor estimator.
    cols: u32,
    rows: u32,
    /// Running cursor estimate (zero-based).
    cursor_row: u32,
    cursor_col: u32,
    /// In-flight OSC 8 hyperlink (start position + url + id), waiting for
    /// the closing `OSC 8;;` sequence.
    pending_link: Option<PendingHyperlink>,
    /// Shared semantic state — wired to the renderer's `Mutex` by
    /// `TerminalRenderer`.
    semantic: Arc<Mutex<TerminalSemanticState>>,
    /// Subscribed listeners. Notified after every state mutation.
    listeners: Arc<Mutex<Vec<Arc<dyn TerminalSemanticStateListener>>>>,
}

#[derive(Debug, Clone)]
struct PendingHyperlink {
    start: TerminalCellPosition,
    url: String,
    id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ParserState {
    /// Default: bytes pass through; CR/LF/Tab update the cursor estimate.
    Ground,
    /// Saw ESC (0x1B); next byte determines the dispatcher.
    Esc,
    /// Saw `ESC [` — absorbing a CSI sequence (e.g. SGR) without
    /// advancing the cursor. We skip parameter bytes (0x30..=0x3F),
    /// intermediates (0x20..=0x2F), and end on the final byte
    /// (0x40..=0x7E).
    Csi,
    /// Saw `ESC ]` — accumulating an OSC payload, terminated by BEL
    /// (0x07) or ST (`ESC \`).
    OscBody,
    /// Inside OSC, just saw ESC — next byte should be `\` (0x5C) for ST,
    /// otherwise we treat it as data and resume accumulation.
    OscEsc,
}

impl OscParser {
    pub fn new(
        semantic: Arc<Mutex<TerminalSemanticState>>,
        listeners: Arc<Mutex<Vec<Arc<dyn TerminalSemanticStateListener>>>>,
    ) -> Self {
        Self {
            state: ParserState::Ground,
            payload: Vec::with_capacity(256),
            payload_overflow: false,
            cols: DEFAULT_COLS,
            rows: DEFAULT_ROWS,
            cursor_row: 0,
            cursor_col: 0,
            pending_link: None,
            semantic,
            listeners,
        }
    }

    /// Update the grid bounds used by the cursor estimator. Callers
    /// should invoke this after every successful resize.
    pub fn set_grid_size(&mut self, cols: u32, rows: u32) {
        self.cols = cols.max(1);
        self.rows = rows.max(1);
        if self.cursor_col >= self.cols {
            self.cursor_col = self.cols.saturating_sub(1);
        }
    }

    /// Feed a chunk of bytes. Bytes that are not part of an in-progress
    /// OSC sequence advance the cursor estimate but are not modified. The
    /// caller is responsible for forwarding the same bytes to Ghostty.
    ///
    /// Returns the number of BEL (0x07) bytes seen in `Ground` state during
    /// this chunk so the renderer can fan a single event out to bell
    /// listeners regardless of how many BELs landed in the burst.
    pub fn feed(&mut self, bytes: &[u8]) -> u32 {
        let mut changed = false;
        let mut bells: u32 = 0;
        for &byte in bytes {
            let (c, bell) = self.feed_byte(byte);
            changed |= c;
            if bell {
                bells = bells.saturating_add(1);
            }
        }
        if changed {
            self.notify();
        }
        bells
    }

    /// Advance one byte through the state machine. Returns
    /// `(semantic_changed, bell)`:
    ///   * `semantic_changed` — caller should run the listener fan-out.
    ///   * `bell` — a BEL (0x07) was observed in `Ground` state, i.e. a
    ///     real `\a` rather than an OSC string terminator.
    fn feed_byte(&mut self, byte: u8) -> (bool, bool) {
        match self.state {
            ParserState::Ground => {
                if byte == 0x1B {
                    self.state = ParserState::Esc;
                    return (false, false);
                }
                if byte == 0x07 {
                    // Real terminal bell. 0x07 is treated as the OSC
                    // string terminator only inside `OscBody`; in Ground
                    // it's a bell.
                    return (false, true);
                }
                self.advance_cursor_ground(byte);
                (false, false)
            }
            ParserState::Esc => {
                match byte {
                    b']' => {
                        self.state = ParserState::OscBody;
                        self.payload.clear();
                        self.payload_overflow = false;
                    }
                    b'[' => {
                        self.state = ParserState::Csi;
                    }
                    // ESC followed by anything else: treat as a non-OSC
                    // escape; return to ground without updating cursor.
                    _ => {
                        self.state = ParserState::Ground;
                    }
                }
                (false, false)
            }
            ParserState::Csi => {
                // CSI parameter (0x30..=0x3F) / intermediate (0x20..=0x2F)
                // / final (0x40..=0x7E). Any final byte ends the sequence.
                if (0x40..=0x7E).contains(&byte) {
                    self.state = ParserState::Ground;
                }
                (false, false)
            }
            ParserState::OscBody => match byte {
                0x07 => (self.complete_osc(), false),
                0x1B => {
                    self.state = ParserState::OscEsc;
                    (false, false)
                }
                _ => {
                    self.push_payload_byte(byte);
                    (false, false)
                }
            },
            ParserState::OscEsc => {
                if byte == b'\\' {
                    (self.complete_osc(), false)
                } else {
                    // Bare ESC inside OSC payload — keep both ESC and the
                    // following byte as data and resume accumulation.
                    self.push_payload_byte(0x1B);
                    self.push_payload_byte(byte);
                    self.state = ParserState::OscBody;
                    (false, false)
                }
            }
        }
    }

    fn push_payload_byte(&mut self, byte: u8) {
        if self.payload_overflow {
            return;
        }
        if self.payload.len() >= MAX_OSC_PAYLOAD {
            self.payload_overflow = true;
            self.payload.clear();
            return;
        }
        self.payload.push(byte);
    }

    /// Called when an OSC terminator (BEL or ST) was seen. Dispatches
    /// the accumulated payload, resets state to Ground, and returns
    /// whether the semantic state was mutated.
    fn complete_osc(&mut self) -> bool {
        self.state = ParserState::Ground;
        if self.payload_overflow {
            self.payload_overflow = false;
            self.payload.clear();
            return false;
        }
        let payload = std::mem::take(&mut self.payload);
        self.dispatch_payload(&payload)
    }

    fn dispatch_payload(&mut self, payload: &[u8]) -> bool {
        // OSC payloads are `<code>;<rest>` where <code> is a decimal
        // identifier. Split on the first semicolon.
        let semi = payload.iter().position(|&b| b == b';');
        let (code_bytes, rest_bytes) = match semi {
            Some(i) => (&payload[..i], &payload[i + 1..]),
            None => (payload, &[][..]),
        };
        let Ok(code_str) = std::str::from_utf8(code_bytes) else {
            return false;
        };
        let Ok(code) = code_str.parse::<u32>() else {
            return false;
        };
        match code {
            0 | 2 => self.handle_title(rest_bytes),
            7 => self.handle_cwd(rest_bytes),
            8 => self.handle_hyperlink(rest_bytes),
            133 => self.handle_prompt(rest_bytes),
            _ => false,
        }
    }

    fn handle_title(&mut self, payload: &[u8]) -> bool {
        let Ok(title) = std::str::from_utf8(payload) else {
            return false;
        };
        let mut guard = self.semantic.lock().unwrap();
        let next = Some(title.to_string());
        if guard.title == next {
            return false;
        }
        guard.title = next;
        true
    }

    fn handle_cwd(&mut self, payload: &[u8]) -> bool {
        let Ok(url) = std::str::from_utf8(payload) else {
            return false;
        };
        let cwd = decode_file_url(url).unwrap_or_else(|| url.to_string());
        let mut guard = self.semantic.lock().unwrap();
        let next = Some(cwd);
        if guard.cwd == next {
            return false;
        }
        guard.cwd = next;
        true
    }

    fn handle_hyperlink(&mut self, payload: &[u8]) -> bool {
        // Format: `params;url`. params is comma-separated key=value list
        // (may be empty). A closing OSC 8 has empty params AND empty url.
        let Ok(payload_str) = std::str::from_utf8(payload) else {
            return false;
        };
        let semi = payload_str.find(';');
        let (params, url) = match semi {
            Some(i) => (&payload_str[..i], &payload_str[i + 1..]),
            None => (payload_str, ""),
        };
        if url.is_empty() {
            // Close any in-flight hyperlink at the current cursor.
            self.close_pending_link()
        } else {
            // Start a new hyperlink. If one was already in-flight,
            // commit it first at the current cursor so we don't lose
            // data.
            self.close_pending_link();
            let id = params
                .split(':')
                .find_map(|kv| kv.strip_prefix("id="))
                .unwrap_or("")
                .to_string();
            self.pending_link = Some(PendingHyperlink {
                start: TerminalCellPosition {
                    row: self.cursor_row,
                    col: self.cursor_col,
                },
                url: url.to_string(),
                id,
            });
            false
        }
    }

    fn close_pending_link(&mut self) -> bool {
        let Some(link) = self.pending_link.take() else {
            return false;
        };
        let end = TerminalCellPosition {
            row: self.cursor_row,
            col: self.cursor_col,
        };
        let mut guard = self.semantic.lock().unwrap();
        guard.hyperlinks.push(TerminalHyperlink {
            start: link.start,
            end,
            url: link.url,
            id: link.id,
        });
        true
    }

    fn handle_prompt(&mut self, payload: &[u8]) -> bool {
        // OSC 133;<C>[;extra...]
        // C is one of A, B, C, D. Any extra parameters are key=value
        // segments (e.g. `cmd=ls`, exit code is a positional after D).
        let Ok(payload_str) = std::str::from_utf8(payload) else {
            return false;
        };
        let mut parts = payload_str.split(';');
        let Some(kind) = parts.next() else {
            return false;
        };
        let row = self.cursor_row;
        let mut guard = self.semantic.lock().unwrap();
        match kind {
            "A" => {
                // Prompt starts. Begin a new mark. Some shells inline a
                // `cmd=...` payload here as well.
                let cmd = extract_cmd(parts);
                guard.prompts.push(TerminalPromptMark {
                    start_row: Some(row),
                    command_row: None,
                    output_row: None,
                    end_row: None,
                    exit_code: None,
                    command_text: cmd,
                });
                true
            }
            "B" => {
                if let Some(mark) = guard.prompts.last_mut()
                    && mark.end_row.is_none() {
                        mark.command_row = Some(row);
                        let cmd = extract_cmd(parts);
                        if !cmd.is_empty() {
                            mark.command_text = cmd;
                        }
                        return true;
                    }
                // No active mark — synthesize one anchored at command row.
                guard.prompts.push(TerminalPromptMark {
                    start_row: None,
                    command_row: Some(row),
                    output_row: None,
                    end_row: None,
                    exit_code: None,
                    command_text: extract_cmd(parts),
                });
                true
            }
            "C" => {
                if let Some(mark) = guard.prompts.last_mut()
                    && mark.end_row.is_none() {
                        mark.output_row = Some(row);
                        return true;
                    }
                guard.prompts.push(TerminalPromptMark {
                    start_row: None,
                    command_row: None,
                    output_row: Some(row),
                    end_row: None,
                    exit_code: None,
                    command_text: String::new(),
                });
                true
            }
            "D" => {
                // First parameter (if present) is the exit code.
                let exit = parts
                    .next()
                    .and_then(|s| s.split('=').next_back())
                    .and_then(|s| s.parse::<i32>().ok());
                if let Some(mark) = guard.prompts.last_mut()
                    && mark.end_row.is_none() {
                        mark.end_row = Some(row);
                        mark.exit_code = exit;
                        return true;
                    }
                // Orphan D: still record so callers see exit signals.
                guard.prompts.push(TerminalPromptMark {
                    start_row: None,
                    command_row: None,
                    output_row: None,
                    end_row: Some(row),
                    exit_code: exit,
                    command_text: String::new(),
                });
                true
            }
            _ => false,
        }
    }

    fn advance_cursor_ground(&mut self, byte: u8) {
        match byte {
            b'\r' => self.cursor_col = 0,
            b'\n' => {
                if self.cursor_row + 1 < u32::MAX {
                    self.cursor_row += 1;
                }
            }
            b'\t' => {
                let next = ((self.cursor_col / TABSTOP) + 1) * TABSTOP;
                self.cursor_col = next.min(self.cols.saturating_sub(1));
            }
            0x08 => {
                if self.cursor_col > 0 {
                    self.cursor_col -= 1;
                }
            }
            // Other C0 controls (0x00..0x1F) do not advance the cursor.
            0x00..=0x1F => {}
            // 0x7F (DEL) is not printable.
            0x7F => {}
            // Treat any other byte (including UTF-8 continuation bytes)
            // as a printable. For multi-byte UTF-8 we advance once per
            // byte but only on the first byte (0x00..=0x7F or 0xC2..);
            // continuation bytes (0x80..=0xBF) do not advance.
            //
            // Wide-char (CJK / emoji) double-width is not modeled — that
            // would require a unicode-width crate and grapheme cluster
            // tracking. The cursor estimate is best-effort; OSC anchor
            // positions are approximate by design (see module docs).
            _ => {
                let is_continuation = (byte & 0xC0) == 0x80;
                if !is_continuation {
                    self.cursor_col += 1;
                    if self.cursor_col >= self.cols {
                        self.cursor_col = 0;
                        if self.cursor_row + 1 < u32::MAX {
                            self.cursor_row += 1;
                        }
                    }
                }
            }
        }
    }

    fn notify(&self) {
        let snapshot = self.semantic.lock().unwrap().clone();
        let listeners = self.listeners.lock().unwrap().clone();
        for listener in listeners {
            listener.on_state_changed(snapshot.clone());
        }
    }
}

/// Pull a `cmd=...` value out of remaining OSC 133 parameter segments.
/// Returns an empty string if none is present. Treats only the *first*
/// `cmd=` occurrence and trims trailing whitespace.
fn extract_cmd<'a, I: Iterator<Item = &'a str>>(parts: I) -> String {
    for part in parts {
        if let Some(rest) = part.strip_prefix("cmd=") {
            return rest.trim().to_string();
        }
    }
    String::new()
}

/// Decode a `file://host/path` URL into the path, percent-decoding common
/// escapes. Returns `None` if the input isn't a `file://` URL — caller
/// falls back to the raw string. We deliberately do not pull in the
/// `url` crate for this: shell OSC 7 payloads use a tiny subset and the
/// path component is what matters.
fn decode_file_url(s: &str) -> Option<String> {
    let after_scheme = s.strip_prefix("file://")?;
    // host/path or /path. Strip the optional host segment.
    let path = match after_scheme.find('/') {
        Some(0) => after_scheme,
        Some(i) => &after_scheme[i..],
        None => "/",
    };
    Some(percent_decode(path))
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len()
            && let (Some(hi), Some(lo)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(10 + b - b'a'),
        b'A'..=b'F' => Some(10 + b - b'A'),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh_parser() -> (
        OscParser,
        Arc<Mutex<TerminalSemanticState>>,
        Arc<Mutex<Vec<Arc<dyn TerminalSemanticStateListener>>>>,
    ) {
        let semantic = Arc::new(Mutex::new(TerminalSemanticState::default()));
        let listeners: Arc<Mutex<Vec<Arc<dyn TerminalSemanticStateListener>>>> =
            Arc::new(Mutex::new(Vec::new()));
        let parser = OscParser::new(semantic.clone(), listeners.clone());
        (parser, semantic, listeners)
    }

    #[test]
    fn osc7_bel_terminated_sets_cwd() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]7;file://localhost/tmp\x07");
        assert_eq!(semantic.lock().unwrap().cwd.as_deref(), Some("/tmp"));
    }

    #[test]
    fn osc7_st_terminated_sets_cwd() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]7;file://host/var/log\x1b\\");
        assert_eq!(
            semantic.lock().unwrap().cwd.as_deref(),
            Some("/var/log")
        );
    }

    #[test]
    fn osc7_percent_decodes_path() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]7;file://host/a%20b/c\x07");
        assert_eq!(semantic.lock().unwrap().cwd.as_deref(), Some("/a b/c"));
    }

    #[test]
    fn osc0_and_osc2_set_title() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]0;hello\x07");
        assert_eq!(semantic.lock().unwrap().title.as_deref(), Some("hello"));
        parser.feed(b"\x1b]2;new title\x1b\\");
        assert_eq!(
            semantic.lock().unwrap().title.as_deref(),
            Some("new title")
        );
    }

    #[test]
    fn osc8_records_hyperlink_with_cell_range() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]8;;https://example.com\x1b\\");
        parser.feed(b"example");
        parser.feed(b"\x1b]8;;\x1b\\");
        let state = semantic.lock().unwrap();
        assert_eq!(state.hyperlinks.len(), 1);
        let link = &state.hyperlinks[0];
        assert_eq!(link.url, "https://example.com");
        assert_eq!(link.start, TerminalCellPosition { row: 0, col: 0 });
        // 7 ASCII chars advances cursor to col 7 on the same row.
        assert_eq!(link.end, TerminalCellPosition { row: 0, col: 7 });
    }

    #[test]
    fn osc8_extracts_id_parameter() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]8;id=abc:foo=bar;https://x.test\x07");
        parser.feed(b"X");
        parser.feed(b"\x1b]8;;\x07");
        let state = semantic.lock().unwrap();
        assert_eq!(state.hyperlinks[0].id, "abc");
    }

    #[test]
    fn osc133_prompt_lifecycle_records_mark() {
        let (mut parser, semantic, _) = fresh_parser();
        // Start at row 0, col 0.
        parser.feed(b"\x1b]133;A\x07$ ");
        // Now cursor at (0, 2). Command starts here.
        parser.feed(b"\x1b]133;B\x07pwd\n");
        // After `pwd\n` cursor is at (1, 0). Output starts.
        parser.feed(b"\x1b]133;C\x07/tmp\n");
        // After `/tmp\n` cursor is at (2, 0). End.
        parser.feed(b"\x1b]133;D;0\x07");
        let state = semantic.lock().unwrap();
        assert_eq!(state.prompts.len(), 1);
        let mark = &state.prompts[0];
        assert_eq!(mark.start_row, Some(0));
        assert_eq!(mark.command_row, Some(0));
        assert_eq!(mark.output_row, Some(1));
        assert_eq!(mark.end_row, Some(2));
        assert_eq!(mark.exit_code, Some(0));
    }

    #[test]
    fn osc133_command_text_from_cmd_param() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]133;A\x07");
        parser.feed(b"\x1b]133;B;cmd=ls -la\x07");
        let state = semantic.lock().unwrap();
        assert_eq!(state.prompts[0].command_text, "ls -la");
    }

    #[test]
    fn osc133_non_zero_exit_recorded() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]133;A\x07\x1b]133;D;127\x07");
        let state = semantic.lock().unwrap();
        assert_eq!(state.prompts[0].exit_code, Some(127));
    }

    #[test]
    fn interleaved_sgr_does_not_break_payload() {
        let (mut parser, semantic, _) = fresh_parser();
        // Realistic shell prompt: SGR + OSC 133;A + text + OSC 133;B.
        parser.feed(b"\x1b[1;32m");
        parser.feed(b"\x1b]133;A\x07");
        parser.feed(b"\x1b[0m");
        parser.feed(b"$ \x1b]133;B\x07");
        parser.feed(b"ls\n");
        let state = semantic.lock().unwrap();
        assert_eq!(state.prompts.len(), 1);
        assert_eq!(state.prompts[0].command_row, Some(0));
    }

    #[test]
    fn split_chunks_complete_osc_across_boundary() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]7;file://h");
        parser.feed(b"/etc/foo");
        parser.feed(b"\x07");
        assert_eq!(
            semantic.lock().unwrap().cwd.as_deref(),
            Some("/etc/foo")
        );
    }

    #[test]
    fn split_chunks_split_st_terminator() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]0;title");
        parser.feed(b"\x1b");
        parser.feed(b"\\");
        assert_eq!(
            semantic.lock().unwrap().title.as_deref(),
            Some("title")
        );
    }

    #[test]
    fn truncated_oversize_payload_is_dropped() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]0;");
        let huge = vec![b'X'; MAX_OSC_PAYLOAD + 32];
        parser.feed(&huge);
        parser.feed(b"\x07");
        // Title not set because payload overflowed.
        assert!(semantic.lock().unwrap().title.is_none());
        // Parser recovers — subsequent OSC parses correctly.
        parser.feed(b"\x1b]2;ok\x07");
        assert_eq!(semantic.lock().unwrap().title.as_deref(), Some("ok"));
    }

    #[test]
    fn unknown_osc_code_is_ignored() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.feed(b"\x1b]42;something\x07");
        let state = semantic.lock().unwrap();
        assert!(state.title.is_none());
        assert!(state.cwd.is_none());
    }

    #[test]
    fn ground_text_advances_cursor_through_wrap() {
        let (mut parser, semantic, _) = fresh_parser();
        parser.set_grid_size(4, 24);
        // 6 chars on a 4-col grid: row 0 fills, cursor wraps to row 1 col 2.
        parser.feed(b"abcdef");
        parser.feed(b"\x1b]133;C\x07");
        let state = semantic.lock().unwrap();
        // After 'abcd' cursor is at (1, 0); 'ef' → (1, 2). OSC133;C
        // records output_row at the cursor row.
        assert_eq!(state.prompts[0].output_row, Some(1));
    }

    #[test]
    fn listener_receives_state_after_change() {
        struct Capturing {
            calls: Arc<Mutex<Vec<TerminalSemanticState>>>,
        }
        impl TerminalSemanticStateListener for Capturing {
            fn on_state_changed(&self, state: TerminalSemanticState) {
                self.calls.lock().unwrap().push(state);
            }
        }
        let (mut parser, _semantic, listeners) = fresh_parser();
        let calls = Arc::new(Mutex::new(Vec::new()));
        listeners
            .lock()
            .unwrap()
            .push(Arc::new(Capturing { calls: calls.clone() }));
        parser.feed(b"\x1b]7;file://h/tmp\x07");
        let recorded = calls.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        assert_eq!(recorded[0].cwd.as_deref(), Some("/tmp"));
    }

    #[test]
    fn ground_bel_counts_once_per_byte() {
        let (mut parser, _semantic, _) = fresh_parser();
        assert_eq!(parser.feed(b"hi\x07there\x07"), 2);
    }

    #[test]
    fn osc_terminator_bel_does_not_count_as_bell() {
        let (mut parser, _semantic, _) = fresh_parser();
        // OSC payload terminated by BEL — this BEL is the ST, not a real
        // bell. Must NOT be counted.
        assert_eq!(parser.feed(b"\x1b]7;file://h/tmp\x07"), 0);
    }

    #[test]
    fn mixed_ground_bell_and_osc_terminator() {
        let (mut parser, _semantic, _) = fresh_parser();
        // Real bell + OSC + real bell. Only the two Ground bells count.
        let n = parser.feed(b"\x07\x1b]2;title\x07\x07");
        assert_eq!(n, 2);
    }

    #[test]
    fn duplicate_cwd_does_not_notify_listener_twice() {
        struct Counting {
            calls: Arc<Mutex<u32>>,
        }
        impl TerminalSemanticStateListener for Counting {
            fn on_state_changed(&self, _state: TerminalSemanticState) {
                *self.calls.lock().unwrap() += 1;
            }
        }
        let (mut parser, _semantic, listeners) = fresh_parser();
        let calls = Arc::new(Mutex::new(0));
        listeners
            .lock()
            .unwrap()
            .push(Arc::new(Counting { calls: calls.clone() }));
        parser.feed(b"\x1b]7;file://h/tmp\x07");
        parser.feed(b"\x1b]7;file://h/tmp\x07");
        // Second OSC 7 with identical cwd should not re-notify.
        assert_eq!(*calls.lock().unwrap(), 1);
    }
}
