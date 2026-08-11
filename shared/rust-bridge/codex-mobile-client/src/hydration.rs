//! Progressive message hydration and LRU caching.
//!
//! Handles paginated message loading (48 initial, 96-chunk), LRU cache
//! with revision-keyed entries, and inline base64 image extraction.

use base64::Engine;
use lru::LruCache;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::num::NonZeroUsize;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::parser::ToolCallCard;

// ---------------------------------------------------------------------------
// MessageHydrator — progressive loading configuration
// ---------------------------------------------------------------------------

/// Controls paginated / progressive message loading.
pub struct MessageHydrator {
    initial_load_count: usize,
    chunk_size: usize,
}

impl MessageHydrator {
    /// Create with default sizes: 48 initial, 96 per chunk.
    pub fn new() -> Self {
        Self {
            initial_load_count: 48,
            chunk_size: 96,
        }
    }

    /// Create with custom sizes.
    pub fn with_sizes(initial: usize, chunk: usize) -> Self {
        Self {
            initial_load_count: initial,
            chunk_size: chunk,
        }
    }

    pub fn initial_load_count(&self) -> usize {
        self.initial_load_count
    }

    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }
}

impl Default for MessageHydrator {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// CacheKey
// ---------------------------------------------------------------------------

/// Uniquely identifies a specific revision of a message for caching.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheKey {
    pub message_id: String,
    pub revision_token: String,
    pub server_id: String,
    pub agent_directory_version: u32,
}

impl fmt::Display for CacheKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}:{}",
            self.message_id, self.revision_token, self.server_id, self.agent_directory_version
        )
    }
}

// ---------------------------------------------------------------------------
// MessageSegment
// ---------------------------------------------------------------------------

/// A parsed segment of assistant message content.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum MessageSegment {
    Text(String),
    InlineImage {
        data: Vec<u8>,
        mime_type: String,
    },
    InlineMath {
        latex: String,
    },
    DisplayMath {
        latex: String,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AppMessageSegment {
    Text {
        text: String,
    },
    InlineImage {
        data: Vec<u8>,
        mime_type: String,
    },
    InlineMath {
        latex: String,
    },
    DisplayMath {
        latex: String,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
}

impl From<MessageSegment> for AppMessageSegment {
    fn from(value: MessageSegment) -> Self {
        match value {
            MessageSegment::Text(text) => Self::Text { text },
            MessageSegment::InlineImage { data, mime_type } => {
                Self::InlineImage { data, mime_type }
            }
            MessageSegment::InlineMath { latex } => Self::InlineMath { latex },
            MessageSegment::DisplayMath { latex } => Self::DisplayMath { latex },
            MessageSegment::CodeBlock { language, code } => Self::CodeBlock { language, code },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum MessageRenderBlock {
    Markdown {
        markdown: String,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
    InlineImage {
        data: Vec<u8>,
        mime_type: String,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AppMessageRenderBlock {
    Markdown {
        markdown: String,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
    InlineImage {
        data: Vec<u8>,
        mime_type: String,
    },
}

impl From<MessageRenderBlock> for AppMessageRenderBlock {
    fn from(value: MessageRenderBlock) -> Self {
        match value {
            MessageRenderBlock::Markdown { markdown } => Self::Markdown { markdown },
            MessageRenderBlock::CodeBlock { language, code } => Self::CodeBlock { language, code },
            MessageRenderBlock::InlineImage { data, mime_type } => {
                Self::InlineImage { data, mime_type }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// CachedMessage
// ---------------------------------------------------------------------------

/// A fully parsed and cached message, ready for rendering.
#[derive(Debug, Clone, Serialize)]
pub struct CachedMessage {
    pub segments: Vec<MessageSegment>,
    pub tool_calls: Vec<ToolCallCard>,
}

// ---------------------------------------------------------------------------
// MessageCache — LRU with trim-down semantics
// ---------------------------------------------------------------------------

/// LRU message cache that trims down to `trim_to` when `max_entries` is exceeded.
pub struct MessageCache {
    cache: LruCache<String, CachedMessage>,
    max_entries: usize,
    trim_to: usize,
}

impl MessageCache {
    /// Create with defaults: max 1024 entries, trim to 768.
    pub fn new() -> Self {
        Self::with_capacity(1024, 768)
    }

    /// Create with custom capacity limits.
    pub fn with_capacity(max: usize, trim_to: usize) -> Self {
        // LruCache needs a NonZeroUsize cap. We use max + 1 so that
        // the LRU itself never auto-evicts before our trim logic runs.
        let lru_cap = NonZeroUsize::new(max + 1).expect("max must be > 0");
        Self {
            cache: LruCache::new(lru_cap),
            max_entries: max,
            trim_to,
        }
    }

    /// Look up a cached message, promoting it in the LRU order.
    pub fn get(&mut self, key: &CacheKey) -> Option<&CachedMessage> {
        let key_str = key.to_string();
        self.cache.get(&key_str)
    }

    /// Insert a message into the cache, trimming if the cache exceeds capacity.
    pub fn insert(&mut self, key: CacheKey, message: CachedMessage) {
        let key_str = key.to_string();
        self.cache.put(key_str, message);
        self.trim_if_needed();
    }

    /// Remove all entries for a given message_id (any revision).
    pub fn invalidate(&mut self, message_id: &str) {
        let prefix = format!("{}:", message_id);
        let keys_to_remove: Vec<String> = self
            .cache
            .iter()
            .filter(|(k, _)| k.starts_with(&prefix))
            .map(|(k, _)| k.clone())
            .collect();
        for k in keys_to_remove {
            self.cache.pop(&k);
        }
    }

    /// Remove all entries.
    pub fn clear(&mut self) {
        self.cache.clear();
    }

    /// Number of entries currently in the cache.
    pub fn len(&self) -> usize {
        self.cache.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.cache.is_empty()
    }

    /// When we exceed `max_entries`, pop the least-recently-used entries
    /// until we are at `trim_to`.
    fn trim_if_needed(&mut self) {
        if self.cache.len() > self.max_entries {
            while self.cache.len() > self.trim_to {
                self.cache.pop_lru();
            }
        }
    }
}

impl Default for MessageCache {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Inline image extraction regex
// ---------------------------------------------------------------------------

/// Matches markdown inline images with data URIs:
///   ![alt](data:image/TYPE;base64,DATA)
/// Also matches bare data URIs (not inside markdown image syntax):
///   data:image/TYPE;base64,DATA
static INLINE_IMAGE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"!\[[^\]]*\]\(data:image/([^;]+);base64,([A-Za-z0-9+/=\s]+)\)")
        .expect("invalid inline image regex")
});

/// Matches bare data URIs that are not part of markdown image syntax.
static BARE_DATA_URI_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"data:image/([^;]+);base64,([A-Za-z0-9+/=]+)").expect("invalid bare data URI regex")
});

// ---------------------------------------------------------------------------
// Segment extraction
// ---------------------------------------------------------------------------

/// Try to decode an inline image from a regex capture (groups 1=mime, 2=base64).
fn decode_image_capture(cap: &regex::Captures<'_>) -> Option<(String, Vec<u8>)> {
    let mime_suffix = cap.get(1)?.as_str();
    let b64_data = cap.get(2)?.as_str();
    let cleaned: String = b64_data.chars().filter(|c| !c.is_whitespace()).collect();
    let engine = base64::engine::general_purpose::STANDARD;
    let bytes = engine.decode(&cleaned).ok()?;
    Some((format!("image/{}", mime_suffix), bytes))
}

/// Find all code fence spans in `text` using a line-based scan.
/// Returns `(byte_start, byte_end, language, code)` tuples.
fn find_code_fences(text: &str) -> Vec<(usize, usize, Option<String>, String)> {
    let mut results = Vec::new();
    let mut fence_char: Option<char> = None;
    let mut fence_len: usize = 0;
    let mut fence_start: usize = 0;
    let mut fence_language = String::new();
    let mut code_lines: Vec<&str> = Vec::new();
    let mut in_fence = false;

    for (line_start, line) in line_byte_offsets(text) {
        let trimmed = line.trim();

        if in_fence {
            // Check if this is the closing fence
            if let Some(fc) = fence_char {
                let close_len = trimmed.chars().take_while(|&c| c == fc).count();
                if close_len >= fence_len && trimmed[fc.len_utf8() * close_len..].trim().is_empty()
                {
                    let line_end = line_start + line.len();
                    let code = code_lines.join("\n");
                    let language = if fence_language.is_empty() {
                        None
                    } else {
                        Some(fence_language.clone())
                    };
                    results.push((fence_start, line_end, language, code));
                    in_fence = false;
                    fence_char = None;
                    code_lines.clear();
                    continue;
                }
            }
            code_lines.push(line);
        } else {
            // Check if this line opens a fence
            let first_char = trimmed.chars().next();
            if let Some(fc) = first_char
                && (fc == '`' || fc == '~') {
                    let fl = trimmed.chars().take_while(|&c| c == fc).count();
                    if fl >= 3 {
                        fence_char = Some(fc);
                        fence_len = fl;
                        fence_start = line_start;
                        fence_language = trimmed[fc.len_utf8() * fl..].trim().to_owned();
                        in_fence = true;
                        code_lines.clear();
                        continue;
                    }
                }
        }
    }

    results
}

/// Iterate over lines with their byte offset in the original string.
fn line_byte_offsets(text: &str) -> Vec<(usize, &str)> {
    let mut result = Vec::new();
    let mut offset = 0;
    for line in text.split('\n') {
        result.push((offset, line));
        offset += line.len() + 1; // +1 for the '\n'
    }
    result
}

fn overlaps_range(start: usize, end: usize, ranges: &[(usize, usize)]) -> bool {
    ranges
        .iter()
        .any(|(range_start, range_end)| start < *range_end && end > *range_start)
}

fn is_escaped(text: &str, index: usize) -> bool {
    if index == 0 {
        return false;
    }

    let bytes = text.as_bytes();
    let mut slash_count = 0usize;
    let mut cursor = index;
    while cursor > 0 {
        cursor -= 1;
        if bytes[cursor] == b'\\' {
            slash_count += 1;
        } else {
            break;
        }
    }

    slash_count % 2 == 1
}

fn find_inline_code_spans(text: &str, excluded_ranges: &[(usize, usize)]) -> Vec<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut cursor = 0usize;

    while cursor < bytes.len() {
        if let Some((_, range_end)) = excluded_ranges
            .iter()
            .find(|(range_start, range_end)| cursor >= *range_start && cursor < *range_end)
        {
            cursor = *range_end;
            continue;
        }

        if bytes[cursor] != b'`' {
            cursor += 1;
            continue;
        }

        let opener_len = bytes[cursor..]
            .iter()
            .take_while(|&&byte| byte == b'`')
            .count();
        let mut search = cursor + opener_len;
        let mut closing_end = None;

        while search < bytes.len() {
            if let Some((_, range_end)) = excluded_ranges
                .iter()
                .find(|(range_start, range_end)| search >= *range_start && search < *range_end)
            {
                search = *range_end;
                continue;
            }

            if bytes[search] == b'`' {
                let run_len = bytes[search..]
                    .iter()
                    .take_while(|&&byte| byte == b'`')
                    .count();
                if run_len == opener_len {
                    closing_end = Some(search + run_len);
                    break;
                }
                search += run_len;
            } else {
                search += 1;
            }
        }

        if let Some(end) = closing_end {
            spans.push((cursor, end));
            cursor = end;
        } else {
            cursor += opener_len;
        }
    }

    spans
}

fn find_closing_math_delimiter(
    text: &str,
    start: usize,
    delimiter: &[u8],
    allow_newlines: bool,
) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut cursor = start;

    while cursor + delimiter.len() <= bytes.len() {
        if !allow_newlines && bytes[cursor] == b'\n' {
            return None;
        }

        if bytes[cursor..].starts_with(delimiter) && !is_escaped(text, cursor) {
            return Some(cursor);
        }

        cursor += 1;
    }

    None
}

fn find_math_spans(
    text: &str,
    excluded_ranges: &[(usize, usize)],
) -> Vec<(usize, usize, MessageSegment)> {
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut cursor = 0usize;

    while cursor < bytes.len() {
        if let Some((_, range_end)) = excluded_ranges
            .iter()
            .find(|(range_start, range_end)| cursor >= *range_start && cursor < *range_end)
        {
            cursor = *range_end;
            continue;
        }

        if bytes[cursor] == b'\\' && !is_escaped(text, cursor) {
            if bytes[cursor..].starts_with(br"\[") {
                if let Some(close_start) =
                    find_closing_math_delimiter(text, cursor + 2, br"\]", true)
                {
                    let latex = &text[cursor + 2..close_start];
                    if !latex.is_empty() {
                        spans.push((
                            cursor,
                            close_start + 2,
                            MessageSegment::DisplayMath {
                                latex: latex.to_owned(),
                            },
                        ));
                        cursor = close_start + 2;
                        continue;
                    }
                }
            } else if bytes[cursor..].starts_with(br"\(")
                && let Some(close_start) =
                    find_closing_math_delimiter(text, cursor + 2, br"\)", false)
                {
                    let latex = &text[cursor + 2..close_start];
                    if !latex.is_empty() && !latex.contains('\n') {
                        spans.push((
                            cursor,
                            close_start + 2,
                            MessageSegment::InlineMath {
                                latex: latex.to_owned(),
                            },
                        ));
                        cursor = close_start + 2;
                        continue;
                    }
                }
        }

        if bytes[cursor] == b'$' && !is_escaped(text, cursor) {
            if cursor + 1 < bytes.len() && bytes[cursor + 1] == b'$' {
                if let Some(close_start) =
                    find_closing_math_delimiter(text, cursor + 2, b"$$", true)
                {
                    let latex = &text[cursor + 2..close_start];
                    if !latex.is_empty() {
                        spans.push((
                            cursor,
                            close_start + 2,
                            MessageSegment::DisplayMath {
                                latex: latex.to_owned(),
                            },
                        ));
                        cursor = close_start + 2;
                        continue;
                    }
                }
            } else if cursor + 1 < bytes.len() && !bytes[cursor + 1].is_ascii_whitespace() {
                let mut search = cursor + 1;
                let mut close_start = None;

                while search < bytes.len() {
                    if bytes[search] == b'\n' {
                        break;
                    }

                    if bytes[search] == b'$'
                        && !is_escaped(text, search)
                        && (search == cursor + 1 || bytes[search - 1] != b'$')
                    {
                        let previous = bytes[search - 1];
                        let next_is_digit = bytes
                            .get(search + 1)
                            .map(|byte| byte.is_ascii_digit())
                            .unwrap_or(false);
                        if !previous.is_ascii_whitespace() && !next_is_digit {
                            close_start = Some(search);
                            break;
                        }
                    }

                    search += 1;
                }

                if let Some(close_start) = close_start {
                    let latex = &text[cursor + 1..close_start];
                    if !latex.is_empty() {
                        spans.push((
                            cursor,
                            close_start + 1,
                            MessageSegment::InlineMath {
                                latex: latex.to_owned(),
                            },
                        ));
                        cursor = close_start + 1;
                        continue;
                    }
                }
            }
        }

        cursor += 1;
    }

    spans
}

/// Extract inline base64 images and code blocks from message text,
/// splitting into typed segments.
///
/// Processing order:
/// 1. Find all inline image matches and code fence spans
/// 2. Sort by position
/// 3. Emit Text / InlineImage / CodeBlock segments in order
pub fn extract_message_segments(text: &str) -> Vec<MessageSegment> {
    if text.is_empty() {
        return Vec::new();
    }

    // Collect all "spans" (start, end, segment) sorted by start position.
    let mut spans: Vec<(usize, usize, MessageSegment)> = Vec::new();
    let code_fences = find_code_fences(text);
    let code_fence_ranges: Vec<(usize, usize)> = code_fences
        .iter()
        .map(|(start, end, _, _)| (*start, *end))
        .collect();
    let inline_code_ranges = find_inline_code_spans(text, &code_fence_ranges);
    let opaque_ranges: Vec<(usize, usize)> = code_fence_ranges
        .iter()
        .copied()
        .chain(inline_code_ranges.iter().copied())
        .collect();

    // Markdown inline images: ![...](data:image/...;base64,...)
    for cap in INLINE_IMAGE_RE.captures_iter(text) {
        let m = cap.get(0).unwrap();
        if overlaps_range(m.start(), m.end(), &opaque_ranges) {
            continue;
        }
        if let Some((mime_type, bytes)) = decode_image_capture(&cap) {
            spans.push((
                m.start(),
                m.end(),
                MessageSegment::InlineImage {
                    data: bytes,
                    mime_type,
                },
            ));
        }
    }

    // Bare data URIs — only add if they don't overlap with markdown image matches
    for cap in BARE_DATA_URI_RE.captures_iter(text) {
        let m = cap.get(0).unwrap();
        let overlaps = overlaps_range(m.start(), m.end(), &opaque_ranges)
            || spans.iter().any(|(s, e, _)| m.start() < *e && m.end() > *s);
        if overlaps {
            continue;
        }
        if let Some((mime_type, bytes)) = decode_image_capture(&cap) {
            spans.push((
                m.start(),
                m.end(),
                MessageSegment::InlineImage {
                    data: bytes,
                    mime_type,
                },
            ));
        }
    }

    for (start, end, language, code) in code_fences {
        spans.push((start, end, MessageSegment::CodeBlock { language, code }));
    }

    for (start, end, segment) in find_math_spans(text, &opaque_ranges) {
        let overlaps = spans.iter().any(|(s, e, _)| start < *e && end > *s);
        if overlaps {
            continue;
        }
        spans.push((start, end, segment));
    }

    if spans.is_empty() {
        return vec![MessageSegment::Text(text.to_owned())];
    }

    spans.sort_by_key(|(start, _, _)| *start);

    // Remove overlapping spans (keep earlier ones)
    let mut deduped: Vec<(usize, usize, MessageSegment)> = Vec::new();
    for span in spans {
        if let Some(last) = deduped.last()
            && span.0 < last.1 {
                continue;
            }
        deduped.push(span);
    }

    let mut segments: Vec<MessageSegment> = Vec::new();
    let mut cursor = 0;

    for (start, end, segment) in deduped {
        if cursor < start {
            let preceding = &text[cursor..start];
            if !preceding.is_empty() {
                segments.push(MessageSegment::Text(preceding.to_owned()));
            }
        }
        segments.push(segment);
        cursor = end;
    }

    // Trailing text
    if cursor < text.len() {
        let remaining = &text[cursor..];
        if !remaining.is_empty() {
            segments.push(MessageSegment::Text(remaining.to_owned()));
        }
    }

    if segments.is_empty() {
        vec![MessageSegment::Text(text.to_owned())]
    } else {
        segments
    }
}

pub fn extract_message_render_blocks(text: &str) -> Vec<MessageRenderBlock> {
    let mut blocks = Vec::new();
    let mut markdown_buffer = String::new();

    for segment in extract_message_segments(text) {
        match segment {
            MessageSegment::Text(text) => {
                markdown_buffer.push_str(&text);
            }
            MessageSegment::InlineMath { latex } => {
                markdown_buffer.push('$');
                markdown_buffer.push_str(&latex);
                markdown_buffer.push('$');
            }
            MessageSegment::DisplayMath { latex } => {
                flush_markdown_buffer(&mut blocks, &mut markdown_buffer);
                blocks.push(MessageRenderBlock::CodeBlock {
                    language: Some("math".to_owned()),
                    code: latex.trim_matches('\n').to_owned(),
                });
            }
            MessageSegment::CodeBlock { language, code } => {
                flush_markdown_buffer(&mut blocks, &mut markdown_buffer);
                blocks.push(MessageRenderBlock::CodeBlock { language, code });
            }
            MessageSegment::InlineImage { data, mime_type } => {
                flush_markdown_buffer(&mut blocks, &mut markdown_buffer);
                blocks.push(MessageRenderBlock::InlineImage { data, mime_type });
            }
        }
    }

    flush_markdown_buffer(&mut blocks, &mut markdown_buffer);

    if blocks.is_empty() && !text.is_empty() {
        blocks.push(MessageRenderBlock::Markdown {
            markdown: text.to_owned(),
        });
    }

    blocks
}

fn flush_markdown_buffer(blocks: &mut Vec<MessageRenderBlock>, markdown_buffer: &mut String) {
    if markdown_buffer.is_empty() {
        return;
    }

    for markdown in crate::markdown_blocks::render_markdown_blocks(markdown_buffer) {
        match markdown {
            crate::markdown_blocks::MarkdownBlock::Markdown(markdown) => {
                if !markdown.is_empty() {
                    blocks.push(MessageRenderBlock::Markdown { markdown });
                }
            }
            crate::markdown_blocks::MarkdownBlock::CodeBlock { language, code } => {
                blocks.push(MessageRenderBlock::CodeBlock { language, code });
            }
            crate::markdown_blocks::MarkdownBlock::ThematicBreak => {
                blocks.push(MessageRenderBlock::Markdown {
                    markdown: "---".to_owned(),
                });
            }
        }
    }

    markdown_buffer.clear();
}

// ---------------------------------------------------------------------------
// FollowScrollTracker
// ---------------------------------------------------------------------------

/// Monotonically incrementing token used by the UI to decide whether
/// to auto-scroll to the bottom of the conversation timeline.
pub struct FollowScrollTracker {
    token: AtomicU64,
}

impl FollowScrollTracker {
    pub fn new() -> Self {
        Self {
            token: AtomicU64::new(0),
        }
    }

    /// Return the current token value.
    pub fn current(&self) -> u64 {
        self.token.load(Ordering::SeqCst)
    }

    /// Increment and return the new token value.
    pub fn increment(&self) -> u64 {
        self.token.fetch_add(1, Ordering::SeqCst) + 1
    }
}

impl Default for FollowScrollTracker {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    // -- MessageHydrator --

    #[test]
    fn test_hydrator_defaults() {
        let h = MessageHydrator::new();
        assert_eq!(h.initial_load_count(), 48);
        assert_eq!(h.chunk_size(), 96);
    }

    #[test]
    fn test_hydrator_custom() {
        let h = MessageHydrator::with_sizes(10, 20);
        assert_eq!(h.initial_load_count(), 10);
        assert_eq!(h.chunk_size(), 20);
    }

    #[test]
    fn test_hydrator_default_trait() {
        let h = MessageHydrator::default();
        assert_eq!(h.initial_load_count(), 48);
    }

    // -- CacheKey --

    #[test]
    fn test_cache_key_display() {
        let key = CacheKey {
            message_id: "msg-1".to_owned(),
            revision_token: "rev-abc".to_owned(),
            server_id: "srv-1".to_owned(),
            agent_directory_version: 3,
        };
        assert_eq!(key.to_string(), "msg-1:rev-abc:srv-1:3");
    }

    #[test]
    fn test_cache_key_equality() {
        let a = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        let b = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        assert_eq!(a, b);
    }

    #[test]
    fn test_cache_key_inequality_revision() {
        let a = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        let b = CacheKey {
            message_id: "m1".into(),
            revision_token: "r2".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        assert_ne!(a, b);
    }

    // -- MessageCache basic operations --

    fn make_key(msg_id: &str, rev: &str) -> CacheKey {
        CacheKey {
            message_id: msg_id.to_owned(),
            revision_token: rev.to_owned(),
            server_id: "srv".to_owned(),
            agent_directory_version: 1,
        }
    }

    fn make_cached(text: &str) -> CachedMessage {
        CachedMessage {
            segments: vec![MessageSegment::Text(text.to_owned())],
            tool_calls: vec![],
        }
    }

    #[test]
    fn test_cache_insert_and_get() {
        let mut cache = MessageCache::new();
        let key = make_key("m1", "r1");
        cache.insert(key.clone(), make_cached("hello"));
        assert_eq!(cache.len(), 1);
        assert!(!cache.is_empty());

        let got = cache.get(&key).unwrap();
        assert_eq!(got.segments.len(), 1);
        match &got.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "hello"),
            _ => panic!("expected Text"),
        }
    }

    #[test]
    fn test_cache_miss() {
        let mut cache = MessageCache::new();
        let key = make_key("m1", "r1");
        assert!(cache.get(&key).is_none());
    }

    #[test]
    fn test_cache_clear() {
        let mut cache = MessageCache::new();
        cache.insert(make_key("m1", "r1"), make_cached("a"));
        cache.insert(make_key("m2", "r1"), make_cached("b"));
        assert_eq!(cache.len(), 2);

        cache.clear();
        assert_eq!(cache.len(), 0);
        assert!(cache.is_empty());
    }

    #[test]
    fn test_cache_invalidate_by_message_id() {
        let mut cache = MessageCache::new();
        cache.insert(make_key("m1", "r1"), make_cached("v1"));
        cache.insert(make_key("m1", "r2"), make_cached("v2"));
        cache.insert(make_key("m2", "r1"), make_cached("other"));
        assert_eq!(cache.len(), 3);

        cache.invalidate("m1");
        assert_eq!(cache.len(), 1);
        assert!(cache.get(&make_key("m1", "r1")).is_none());
        assert!(cache.get(&make_key("m1", "r2")).is_none());
        assert!(cache.get(&make_key("m2", "r1")).is_some());
    }

    // -- LRU eviction --

    #[test]
    fn test_lru_eviction_trims_to_target() {
        // max=8, trim_to=4
        let mut cache = MessageCache::with_capacity(8, 4);

        // Insert 9 items → exceeds max of 8, should trim to 4
        for i in 0..9 {
            cache.insert(
                make_key(&format!("m{}", i), "r1"),
                make_cached(&format!("v{}", i)),
            );
        }

        assert_eq!(cache.len(), 4);

        // The most recently inserted items should survive
        assert!(cache.get(&make_key("m8", "r1")).is_some());
        assert!(cache.get(&make_key("m7", "r1")).is_some());
        assert!(cache.get(&make_key("m6", "r1")).is_some());
        assert!(cache.get(&make_key("m5", "r1")).is_some());

        // Older items should be evicted
        assert!(cache.get(&make_key("m0", "r1")).is_none());
        assert!(cache.get(&make_key("m1", "r1")).is_none());
        assert!(cache.get(&make_key("m2", "r1")).is_none());
        assert!(cache.get(&make_key("m3", "r1")).is_none());
        assert!(cache.get(&make_key("m4", "r1")).is_none());
    }

    #[test]
    fn test_lru_eviction_1025_trims_to_768() {
        let mut cache = MessageCache::new(); // max 1024, trim_to 768

        for i in 0..1025 {
            cache.insert(
                make_key(&format!("msg-{}", i), "r1"),
                make_cached(&format!("value-{}", i)),
            );
        }

        assert_eq!(cache.len(), 768);

        // Most recent should survive
        assert!(cache.get(&make_key("msg-1024", "r1")).is_some());
        assert!(cache.get(&make_key("msg-1023", "r1")).is_some());

        // Oldest should be evicted
        assert!(cache.get(&make_key("msg-0", "r1")).is_none());
        assert!(cache.get(&make_key("msg-1", "r1")).is_none());
    }

    #[test]
    fn test_lru_access_order_promotion() {
        // max=4, trim_to=2
        let mut cache = MessageCache::with_capacity(4, 2);

        // Insert 4 items
        cache.insert(make_key("m0", "r1"), make_cached("v0"));
        cache.insert(make_key("m1", "r1"), make_cached("v1"));
        cache.insert(make_key("m2", "r1"), make_cached("v2"));
        cache.insert(make_key("m3", "r1"), make_cached("v3"));

        // Access m0 to promote it (most recently used)
        assert!(cache.get(&make_key("m0", "r1")).is_some());

        // Insert one more → triggers trim from 5 → 2
        cache.insert(make_key("m4", "r1"), make_cached("v4"));

        assert_eq!(cache.len(), 2);

        // m4 (just inserted) and m0 (recently accessed) should survive
        assert!(cache.get(&make_key("m4", "r1")).is_some());
        assert!(cache.get(&make_key("m0", "r1")).is_some());

        // m1, m2, m3 should be evicted
        assert!(cache.get(&make_key("m1", "r1")).is_none());
        assert!(cache.get(&make_key("m2", "r1")).is_none());
        assert!(cache.get(&make_key("m3", "r1")).is_none());
    }

    // -- extract_message_segments --

    #[test]
    fn test_extract_plain_text() {
        let segs = extract_message_segments("Hello, world!");
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0], MessageSegment::Text("Hello, world!".to_owned()));
    }

    #[test]
    fn test_extract_empty() {
        let segs = extract_message_segments("");
        assert!(segs.is_empty());
    }

    #[test]
    fn test_extract_code_block() {
        let text = "Before\n```python\nprint('hi')\n```\nAfter";
        let segs = extract_message_segments(text);

        assert_eq!(segs.len(), 3);
        assert_eq!(segs[0], MessageSegment::Text("Before\n".to_owned()));
        assert_eq!(
            segs[1],
            MessageSegment::CodeBlock {
                language: Some("python".to_owned()),
                code: "print('hi')".to_owned(),
            }
        );
        assert_eq!(segs[2], MessageSegment::Text("\nAfter".to_owned()));
    }

    #[test]
    fn test_extract_code_block_no_language() {
        let text = "```\nsome code\n```";
        let segs = extract_message_segments(text);

        assert_eq!(segs.len(), 1);
        assert_eq!(
            segs[0],
            MessageSegment::CodeBlock {
                language: None,
                code: "some code".to_owned(),
            }
        );
    }

    #[test]
    fn test_extract_inline_image_markdown() {
        // Create a small 1x1 red PNG as base64
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "Before image ![alt](data:image/png;base64,{}) after image",
            png_b64
        );

        let segs = extract_message_segments(&text);
        assert_eq!(segs.len(), 3);

        assert_eq!(segs[0], MessageSegment::Text("Before image ".to_owned()));

        match &segs[1] {
            MessageSegment::InlineImage { data, mime_type } => {
                assert_eq!(mime_type, "image/png");
                assert!(!data.is_empty());
                // PNG magic bytes
                assert_eq!(&data[..4], &[0x89, 0x50, 0x4E, 0x47]);
            }
            other => panic!("Expected InlineImage, got {:?}", other),
        }

        assert_eq!(segs[2], MessageSegment::Text(" after image".to_owned()));
    }

    #[test]
    fn test_extract_inline_image_bare_data_uri() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!("Look at this: data:image/png;base64,{} cool", png_b64);

        let segs = extract_message_segments(&text);
        // Should have text before, image, text after
        assert!(segs.len() >= 2);

        let has_image = segs
            .iter()
            .any(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(has_image);
    }

    #[test]
    fn test_extract_jpeg_mime_type() {
        // Minimal JPEG-like base64 (won't be a valid JPEG but tests mime extraction)
        let text = "![photo](data:image/jpeg;base64,/9j/4AAQSkZJRg==)";
        let segs = extract_message_segments(text);

        let image_seg = segs
            .iter()
            .find(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(image_seg.is_some());

        match image_seg.unwrap() {
            MessageSegment::InlineImage { mime_type, .. } => {
                assert_eq!(mime_type, "image/jpeg");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn test_extract_mixed_content() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "# Heading\n\nSome text\n\n![img](data:image/png;base64,{})\n\n```rust\nfn main() {{}}\n```\n\nTrailing text",
            png_b64
        );

        let segs = extract_message_segments(&text);

        let text_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::Text(_)))
            .count();
        let image_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::InlineImage { .. }))
            .count();
        let code_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::CodeBlock { .. }))
            .count();

        assert!(text_count >= 1, "should have at least one text segment");
        assert_eq!(image_count, 1, "should have exactly one image");
        assert_eq!(code_count, 1, "should have exactly one code block");
    }

    #[test]
    fn test_extract_invalid_base64_skipped() {
        let text = "![bad](data:image/png;base64,!!!not-valid-base64!!!)";
        let segs = extract_message_segments(text);
        // Invalid base64 should not produce an InlineImage segment
        let has_image = segs
            .iter()
            .any(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(!has_image);
    }

    #[test]
    fn test_extract_multiple_images() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "![a](data:image/png;base64,{}) middle ![b](data:image/png;base64,{})",
            png_b64, png_b64
        );

        let segs = extract_message_segments(&text);
        let image_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::InlineImage { .. }))
            .count();
        assert_eq!(image_count, 2);
    }

    #[test]
    fn test_extract_base64_with_whitespace() {
        // base64 with embedded whitespace should still decode
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAf\nFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!("![img](data:image/png;base64,{})", png_b64);

        let segs = extract_message_segments(&text);
        let has_image = segs
            .iter()
            .any(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(has_image, "whitespace in base64 should still decode");
    }

    #[test]
    fn test_extract_render_blocks_splits_markdown_code_and_images() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "# Heading\n\nParagraph.\n\n![img](data:image/png;base64,{png_b64})\n\n```swift\nprint(\"hi\")\n```\n\nAfter"
        );

        let blocks = extract_message_render_blocks(&text);

        assert_eq!(
            blocks,
            vec![
                MessageRenderBlock::Markdown {
                    markdown: "# Heading".to_owned(),
                },
                MessageRenderBlock::Markdown {
                    markdown: "Paragraph.".to_owned(),
                },
                MessageRenderBlock::InlineImage {
                    data: base64::engine::general_purpose::STANDARD
                        .decode(png_b64)
                        .unwrap(),
                    mime_type: "image/png".to_owned(),
                },
                MessageRenderBlock::CodeBlock {
                    language: Some("swift".to_owned()),
                    code: "print(\"hi\")".to_owned(),
                },
                MessageRenderBlock::Markdown {
                    markdown: "After".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn test_extract_render_blocks_keeps_thematic_break_and_display_math_separate() {
        let blocks = extract_message_render_blocks("Before\n\n---\n\n$$x^2$$\n\nAfter");

        assert_eq!(
            blocks,
            vec![
                MessageRenderBlock::Markdown {
                    markdown: "Before".to_owned(),
                },
                MessageRenderBlock::Markdown {
                    markdown: "---".to_owned(),
                },
                MessageRenderBlock::CodeBlock {
                    language: Some("math".to_owned()),
                    code: "x^2".to_owned(),
                },
                MessageRenderBlock::Markdown {
                    markdown: "After".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn test_extract_inline_math() {
        let segs = extract_message_segments("Euler: $e^{i\\pi}+1=0$ wow");

        assert_eq!(
            segs,
            vec![
                MessageSegment::Text("Euler: ".to_owned()),
                MessageSegment::InlineMath {
                    latex: "e^{i\\pi}+1=0".to_owned(),
                },
                MessageSegment::Text(" wow".to_owned()),
            ]
        );
    }

    #[test]
    fn test_extract_display_math() {
        let segs = extract_message_segments("Before\n$$\\int_0^1 x^2 dx$$\nAfter");

        assert_eq!(
            segs,
            vec![
                MessageSegment::Text("Before\n".to_owned()),
                MessageSegment::DisplayMath {
                    latex: "\\int_0^1 x^2 dx".to_owned(),
                },
                MessageSegment::Text("\nAfter".to_owned()),
            ]
        );
    }

    #[test]
    fn test_extract_escaped_math_delimiters_as_text() {
        let segs = extract_message_segments("Price is \\$5 and not math");
        assert_eq!(
            segs,
            vec![MessageSegment::Text(
                "Price is \\$5 and not math".to_owned()
            )]
        );
    }

    #[test]
    fn test_extract_currency_and_unclosed_delimiters_as_text() {
        let segs = extract_message_segments("Price is $5 and $unfinished");
        assert_eq!(
            segs,
            vec![MessageSegment::Text(
                "Price is $5 and $unfinished".to_owned()
            )]
        );
    }

    #[test]
    fn test_extract_math_skips_inline_code() {
        let segs = extract_message_segments("Use `$x$` literally and $y$ for math");
        assert_eq!(
            segs,
            vec![
                MessageSegment::Text("Use `$x$` literally and ".to_owned()),
                MessageSegment::InlineMath {
                    latex: "y".to_owned(),
                },
                MessageSegment::Text(" for math".to_owned()),
            ]
        );
    }

    #[test]
    fn test_extract_math_skips_fenced_code() {
        let segs = extract_message_segments("```tex\n$x$\n```\n\n$y$");
        assert_eq!(
            segs,
            vec![
                MessageSegment::CodeBlock {
                    language: Some("tex".to_owned()),
                    code: "$x$".to_owned(),
                },
                MessageSegment::Text("\n\n".to_owned()),
                MessageSegment::InlineMath {
                    latex: "y".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn test_extract_backslash_math_delimiters() {
        let segs = extract_message_segments(r"Inline \(a+b\) and block \[c+d\]");
        assert_eq!(
            segs,
            vec![
                MessageSegment::Text("Inline ".to_owned()),
                MessageSegment::InlineMath {
                    latex: "a+b".to_owned(),
                },
                MessageSegment::Text(" and block ".to_owned()),
                MessageSegment::DisplayMath {
                    latex: "c+d".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn test_render_blocks_keep_display_math_as_code_block() {
        let blocks = extract_message_render_blocks("Before\n\n\\[\nc+d\n\\]\n\nAfter");
        assert_eq!(
            blocks,
            vec![
                MessageRenderBlock::Markdown {
                    markdown: "Before".to_owned(),
                },
                MessageRenderBlock::CodeBlock {
                    language: Some("math".to_owned()),
                    code: "c+d".to_owned(),
                },
                MessageRenderBlock::Markdown {
                    markdown: "After".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn test_render_blocks_keep_inline_math_inside_markdown_paragraph() {
        let blocks = extract_message_render_blocks("Euler: $e^{i\\pi}+1=0$ wow");
        assert_eq!(
            blocks,
            vec![MessageRenderBlock::Markdown {
                markdown: "Euler: $e^{i\\pi}+1=0$ wow".to_owned(),
            }]
        );
    }

    #[test]
    fn test_render_blocks_keep_inline_math_with_surrounding_markdown() {
        let blocks = extract_message_render_blocks("Before **$x$** after");
        assert_eq!(
            blocks,
            vec![MessageRenderBlock::Markdown {
                markdown: "Before **$x$** after".to_owned(),
            }]
        );
    }

    #[test]
    fn test_render_blocks_keep_inline_images_separate() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn8Vf0AAAAASUVORK5CYII=";
        let text = format!("Intro ![](data:image/png;base64,{png_b64}) Outro");
        let blocks = extract_message_render_blocks(&text);

        assert!(matches!(
            blocks.as_slice(),
            [
                MessageRenderBlock::Markdown { .. },
                MessageRenderBlock::InlineImage { mime_type, .. },
                MessageRenderBlock::Markdown { .. }
            ] if mime_type == "image/png"
        ));
    }

    // -- FollowScrollTracker --

    #[test]
    fn test_follow_scroll_initial() {
        let tracker = FollowScrollTracker::new();
        assert_eq!(tracker.current(), 0);
    }

    #[test]
    fn test_follow_scroll_increment() {
        let tracker = FollowScrollTracker::new();
        assert_eq!(tracker.increment(), 1);
        assert_eq!(tracker.increment(), 2);
        assert_eq!(tracker.current(), 2);
    }

    #[test]
    fn test_follow_scroll_default() {
        let tracker = FollowScrollTracker::default();
        assert_eq!(tracker.current(), 0);
    }

    // -- Cache key matching --

    #[test]
    fn test_cache_key_same_message_different_server() {
        let mut cache = MessageCache::new();
        let key_a = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "server-a".into(),
            agent_directory_version: 1,
        };
        let key_b = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "server-b".into(),
            agent_directory_version: 1,
        };

        cache.insert(key_a.clone(), make_cached("from server A"));
        cache.insert(key_b.clone(), make_cached("from server B"));

        assert_eq!(cache.len(), 2);

        let a = cache.get(&key_a).unwrap();
        match &a.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "from server A"),
            _ => panic!("expected text"),
        }

        let b = cache.get(&key_b).unwrap();
        match &b.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "from server B"),
            _ => panic!("expected text"),
        }
    }

    #[test]
    fn test_cache_key_different_agent_directory_version() {
        let mut cache = MessageCache::new();
        let key_v1 = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "srv".into(),
            agent_directory_version: 1,
        };
        let key_v2 = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "srv".into(),
            agent_directory_version: 2,
        };

        cache.insert(key_v1.clone(), make_cached("v1"));
        cache.insert(key_v2.clone(), make_cached("v2"));

        assert_eq!(cache.len(), 2);
        assert!(cache.get(&key_v1).is_some());
        assert!(cache.get(&key_v2).is_some());
    }

    #[test]
    fn test_cache_overwrite_same_key() {
        let mut cache = MessageCache::new();
        let key = make_key("m1", "r1");

        cache.insert(key.clone(), make_cached("first"));
        cache.insert(key.clone(), make_cached("second"));

        assert_eq!(cache.len(), 1);
        let got = cache.get(&key).unwrap();
        match &got.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "second"),
            _ => panic!("expected text"),
        }
    }

    // -- Integration: cache + extract --

    #[test]
    fn test_cache_with_extracted_segments() {
        let mut cache = MessageCache::new();
        let text = "Hello\n```rust\nfn main() {}\n```\nGoodbye";
        let segments = extract_message_segments(text);
        let key = make_key("m1", "r1");

        cache.insert(
            key.clone(),
            CachedMessage {
                segments,
                tool_calls: vec![],
            },
        );

        let cached = cache.get(&key).unwrap();
        assert_eq!(cached.segments.len(), 3);
    }
}
