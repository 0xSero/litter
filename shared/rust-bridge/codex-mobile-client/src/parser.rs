//! Tool call message parser: markdown-structured system messages → typed tool cards.
//!
//! Parses `### [Title]` headers, metadata lines, code fences, and named sections
//! into `ToolCallCard` structs for rendering on both platforms.

use regex::Regex;
use serde::Deserialize;
use std::sync::LazyLock;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallCard {
    pub kind: ToolCallKind,
    pub title: String,
    pub summary: Option<String>,
    pub status: ToolCallStatus,
    /// Duration in milliseconds (for JSON serialization).
    #[serde(serialize_with = "serialize_opt_duration")]
    pub duration: Option<std::time::Duration>,
    pub target: Option<ToolCallTarget>,
    pub sections: Vec<ToolCallSection>,
}

fn serialize_opt_duration<S: serde::Serializer>(
    duration: &Option<std::time::Duration>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match duration {
        Some(d) => serializer.serialize_u64(d.as_millis() as u64),
        None => serializer.serialize_none(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ToolCallKind {
    CommandExecution,
    CommandOutput,
    FileChange,
    FileDiff,
    McpToolCall,
    McpToolProgress,
    WebSearch,
    Collaboration,
    ImageView,
    Widget,
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum ToolCallStatus {
    InProgress,
    Completed,
    Failed,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallTarget {
    pub agent_nickname: Option<String>,
    pub role: Option<String>,
    pub display_label: String,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallSection {
    pub name: String,
    pub content: SectionContent,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SectionContent {
    KeyValue(Vec<(String, String)>),
    Code {
        language: Option<String>,
        code: String,
    },
    Json(serde_json::Value),
    Diff(String),
    Text(String),
    List(Vec<String>),
    Progress {
        current: u64,
        total: u64,
        label: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AppToolCallKind {
    CommandExecution,
    CommandOutput,
    FileChange,
    FileDiff,
    McpToolCall,
    McpToolProgress,
    WebSearch,
    Collaboration,
    ImageView,
    Widget,
    Unknown { raw: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppToolCallKeyValue {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AppToolCallSectionContent {
    KeyValue { entries: Vec<AppToolCallKeyValue> },
    Code { language: String, content: String },
    Json { content: String },
    Diff { content: String },
    Text { content: String },
    ItemList { items: Vec<String> },
    ProgressList { items: Vec<String> },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppToolCallSection {
    pub label: String,
    pub content: AppToolCallSectionContent,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppToolCallCard {
    pub kind: AppToolCallKind,
    pub title: String,
    pub summary: String,
    pub status: ToolCallStatus,
    pub duration_ms: Option<u64>,
    pub target_label: Option<String>,
    pub sections: Vec<AppToolCallSection>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct CodeReviewPayload {
    pub findings: Vec<CodeReviewFinding>,
    pub overall_correctness: Option<String>,
    pub overall_explanation: Option<String>,
    pub overall_confidence_score: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct CodeReviewFinding {
    pub title: String,
    pub body: String,
    pub confidence_score: f64,
    pub priority: Option<u8>,
    pub code_location: Option<CodeReviewCodeLocation>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct CodeReviewCodeLocation {
    pub absolute_file_path: String,
    pub line_range: Option<CodeReviewLineRange>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct CodeReviewLineRange {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppCodeReviewPayload {
    pub findings: Vec<AppCodeReviewFinding>,
    pub overall_correctness: Option<String>,
    pub overall_explanation: Option<String>,
    pub overall_confidence_score: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppCodeReviewFinding {
    pub title: String,
    pub body: String,
    pub confidence_score: f64,
    pub priority: Option<u8>,
    pub code_location: Option<AppCodeReviewCodeLocation>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppCodeReviewCodeLocation {
    pub absolute_file_path: String,
    pub line_range: Option<AppCodeReviewLineRange>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppCodeReviewLineRange {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Deserialize)]
struct RawCodeReviewPayload {
    findings: Vec<RawCodeReviewFinding>,
    #[serde(default, deserialize_with = "deserialize_optional_stringified_value")]
    overall_correctness: Option<String>,
    #[serde(default)]
    overall_explanation: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    overall_confidence_score: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct RawCodeReviewFinding {
    title: String,
    body: String,
    #[serde(deserialize_with = "deserialize_f64")]
    confidence_score: f64,
    #[serde(default, deserialize_with = "deserialize_optional_u8")]
    priority: Option<u8>,
    #[serde(default)]
    code_location: Option<RawCodeReviewCodeLocation>,
}

#[derive(Debug, Deserialize)]
struct RawCodeReviewCodeLocation {
    absolute_file_path: String,
    #[serde(default)]
    line_range: Option<RawCodeReviewLineRange>,
}

#[derive(Debug, Deserialize)]
struct RawCodeReviewLineRange {
    #[serde(deserialize_with = "deserialize_u32")]
    start: u32,
    #[serde(deserialize_with = "deserialize_u32")]
    end: u32,
}

impl From<&ToolCallKind> for AppToolCallKind {
    fn from(value: &ToolCallKind) -> Self {
        match value {
            ToolCallKind::CommandExecution => Self::CommandExecution,
            ToolCallKind::CommandOutput => Self::CommandOutput,
            ToolCallKind::FileChange => Self::FileChange,
            ToolCallKind::FileDiff => Self::FileDiff,
            ToolCallKind::McpToolCall => Self::McpToolCall,
            ToolCallKind::McpToolProgress => Self::McpToolProgress,
            ToolCallKind::WebSearch => Self::WebSearch,
            ToolCallKind::Collaboration => Self::Collaboration,
            ToolCallKind::ImageView => Self::ImageView,
            ToolCallKind::Widget => Self::Widget,
            ToolCallKind::Unknown(raw) => Self::Unknown { raw: raw.clone() },
        }
    }
}

impl From<&ToolCallSection> for AppToolCallSection {
    fn from(value: &ToolCallSection) -> Self {
        Self {
            label: value.name.clone(),
            content: (&value.content).into(),
        }
    }
}

impl From<&SectionContent> for AppToolCallSectionContent {
    fn from(value: &SectionContent) -> Self {
        match value {
            SectionContent::KeyValue(entries) => Self::KeyValue {
                entries: entries
                    .iter()
                    .map(|(key, value)| AppToolCallKeyValue {
                        key: key.clone(),
                        value: value.clone(),
                    })
                    .collect(),
            },
            SectionContent::Code { language, code } => Self::Code {
                language: language.clone().unwrap_or_default(),
                content: code.clone(),
            },
            SectionContent::Json(value) => Self::Json {
                content: serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".to_string()),
            },
            SectionContent::Diff(value) => Self::Diff {
                content: value.clone(),
            },
            SectionContent::Text(value) => Self::Text {
                content: value.clone(),
            },
            SectionContent::List(items) => Self::ItemList {
                items: items.clone(),
            },
            SectionContent::Progress {
                current,
                total,
                label,
            } => {
                let prefix = label
                    .as_ref()
                    .map(|label| format!("{label}: "))
                    .unwrap_or_default();
                Self::ProgressList {
                    items: vec![format!("{prefix}{current}/{total}")],
                }
            }
        }
    }
}

impl From<&ToolCallCard> for AppToolCallCard {
    fn from(value: &ToolCallCard) -> Self {
        Self {
            kind: (&value.kind).into(),
            title: value.title.clone(),
            summary: value.summary.clone().unwrap_or_else(|| value.title.clone()),
            status: value.status.clone(),
            duration_ms: value.duration.map(|duration| duration.as_millis() as u64),
            target_label: value
                .target
                .as_ref()
                .map(|target| target.display_label.clone()),
            sections: value
                .sections
                .iter()
                .map(AppToolCallSection::from)
                .collect(),
        }
    }
}

impl From<&CodeReviewPayload> for AppCodeReviewPayload {
    fn from(value: &CodeReviewPayload) -> Self {
        Self {
            findings: value
                .findings
                .iter()
                .map(AppCodeReviewFinding::from)
                .collect(),
            overall_correctness: value.overall_correctness.clone(),
            overall_explanation: value.overall_explanation.clone(),
            overall_confidence_score: value.overall_confidence_score,
        }
    }
}

impl From<&CodeReviewFinding> for AppCodeReviewFinding {
    fn from(value: &CodeReviewFinding) -> Self {
        Self {
            title: value.title.clone(),
            body: value.body.clone(),
            confidence_score: value.confidence_score,
            priority: value.priority,
            code_location: value
                .code_location
                .as_ref()
                .map(AppCodeReviewCodeLocation::from),
        }
    }
}

impl From<&CodeReviewCodeLocation> for AppCodeReviewCodeLocation {
    fn from(value: &CodeReviewCodeLocation) -> Self {
        Self {
            absolute_file_path: value.absolute_file_path.clone(),
            line_range: value.line_range.as_ref().map(AppCodeReviewLineRange::from),
        }
    }
}

impl From<&CodeReviewLineRange> for AppCodeReviewLineRange {
    fn from(value: &CodeReviewLineRange) -> Self {
        Self {
            start: value.start,
            end: value.end,
        }
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Known leading metadata keys (normalized).
const LEADING_KEY_SET: &[&str] = &[
    "status",
    "tool",
    "duration",
    "path",
    "kind",
    "query",
    "targets",
    "exit code",
    "directory",
    "approval",
    "error",
];

/// Known named-section labels (normalized).
const NAMED_SECTION_SET: &[&str] = &[
    "command",
    "arguments",
    "result",
    "output",
    "targets",
    "prompt",
    "action",
    "progress",
    "error",
];

static NORMALIZE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^a-z0-9]+").expect("invalid regex"));

static BULLET_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?:[-*•]\s+|\d+\.\s+)").expect("invalid regex"));

static FINDING_PRIORITY_PREFIX_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\[(p[0-3])\]\s*").expect("invalid regex"));

static WINDOWS_DRIVE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^([a-z]):/(.*)$").expect("invalid regex"));

fn normalize_token(s: &str) -> String {
    let lower = s.trim().to_lowercase();
    let replaced = NORMALIZE_RE.replace_all(&lower, " ");
    replaced.trim().to_owned()
}

fn is_leading_key(normalized: &str) -> bool {
    LEADING_KEY_SET.contains(&normalized)
}

fn is_named_section(normalized: &str) -> bool {
    NAMED_SECTION_SET.contains(&normalized)
}

fn deserialize_optional_stringified_value<'de, D>(
    deserializer: D,
) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(value.and_then(|value| match value {
        serde_json::Value::Null => None,
        serde_json::Value::String(text) => {
            let trimmed = text.trim().to_owned();
            (!trimmed.is_empty()).then_some(trimmed)
        }
        serde_json::Value::Bool(boolean) => Some(boolean.to_string()),
        serde_json::Value::Number(number) => Some(number.to_string()),
        other @ (serde_json::Value::Array(_) | serde_json::Value::Object(_)) => {
            serde_json::to_string(&other).ok()
        }
    }))
}

fn deserialize_optional_f64<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    value
        .map(parse_json_f64)
        .transpose()
        .map_err(serde::de::Error::custom)
}

fn deserialize_f64<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    parse_json_f64(value).map_err(serde::de::Error::custom)
}

fn deserialize_optional_u8<'de, D>(deserializer: D) -> Result<Option<u8>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    value
        .map(parse_json_u8)
        .transpose()
        .map_err(serde::de::Error::custom)
}

fn deserialize_u32<'de, D>(deserializer: D) -> Result<u32, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    parse_json_u32(value).map_err(serde::de::Error::custom)
}

fn parse_json_f64(value: serde_json::Value) -> Result<f64, String> {
    match value {
        serde_json::Value::Number(number) => number
            .as_f64()
            .ok_or_else(|| "expected finite number".to_string()),
        serde_json::Value::String(text) => text
            .trim()
            .parse::<f64>()
            .map_err(|_| format!("invalid number: {text}")),
        other => Err(format!("expected number, got {other}")),
    }
}

fn parse_json_u8(value: serde_json::Value) -> Result<u8, String> {
    match value {
        serde_json::Value::Number(number) => number
            .as_u64()
            .and_then(|value| u8::try_from(value).ok())
            .ok_or_else(|| "expected u8".to_string()),
        serde_json::Value::String(text) => text
            .trim()
            .parse::<u8>()
            .map_err(|_| format!("invalid integer: {text}")),
        other => Err(format!("expected integer, got {other}")),
    }
}

fn parse_json_u32(value: serde_json::Value) -> Result<u32, String> {
    match value {
        serde_json::Value::Number(number) => number
            .as_u64()
            .and_then(|value| u32::try_from(value).ok())
            .ok_or_else(|| "expected u32".to_string()),
        serde_json::Value::String(text) => text
            .trim()
            .parse::<u32>()
            .map_err(|_| format!("invalid integer: {text}")),
        other => Err(format!("expected integer, got {other}")),
    }
}

fn normalize_priority_and_title(title: &str, priority: Option<u8>) -> (String, Option<u8>) {
    let trimmed = title.trim();
    let inferred_priority = FINDING_PRIORITY_PREFIX_RE
        .captures(trimmed)
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str())
        .map(|value| value.trim_start_matches(['P', 'p']))
        .and_then(|value| value.parse::<u8>().ok());
    let normalized_title = FINDING_PRIORITY_PREFIX_RE
        .replace(trimmed, "")
        .trim()
        .to_owned();
    (
        if normalized_title.is_empty() {
            trimmed.to_owned()
        } else {
            normalized_title
        },
        priority.or(inferred_priority),
    )
}

fn normalize_review_path(path: &str) -> String {
    let mut normalized = path.trim().replace('\\', "/");
    if normalized.is_empty() {
        return normalized;
    }

    if let Some(stripped) = normalized.strip_prefix("//?/") {
        normalized = stripped.to_owned();
    } else if let Some(stripped) = normalized.strip_prefix("/?/") {
        normalized = stripped.to_owned();
    }

    let lower = normalized.to_ascii_lowercase();
    for prefix in ["//wsl$/", "//wsl.localhost/"] {
        if lower.starts_with(prefix) {
            let remainder = &normalized[prefix.len()..];
            if let Some((_, path_after_distro)) = remainder.split_once('/') {
                return collapse_repeated_slashes(&format!("/{path_after_distro}"));
            }
            return "/".to_string();
        }
    }

    if let Some(captures) = WINDOWS_DRIVE_RE.captures(&normalized) {
        let drive = captures
            .get(1)
            .map(|value| value.as_str().to_ascii_lowercase())
            .unwrap_or_else(|| "c".to_string());
        let rest = captures
            .get(2)
            .map(|value| value.as_str())
            .unwrap_or_default();
        return collapse_repeated_slashes(&format!("/mnt/{drive}/{rest}"));
    }

    if let Some(stripped) = normalized.strip_prefix("//") {
        let remainder = collapse_repeated_slashes(stripped);
        return format!("//{remainder}");
    }

    collapse_repeated_slashes(&normalized)
}

fn collapse_repeated_slashes(path: &str) -> String {
    let mut collapsed = String::with_capacity(path.len());
    let mut previous_was_slash = false;
    for character in path.chars() {
        if character == '/' {
            if !previous_was_slash {
                collapsed.push(character);
            }
            previous_was_slash = true;
        } else {
            collapsed.push(character);
            previous_was_slash = false;
        }
    }
    collapsed
}

fn normalize_line_range(range: RawCodeReviewLineRange) -> CodeReviewLineRange {
    let start = range.start;
    let end = range.end.max(start);
    CodeReviewLineRange { start, end }
}

fn normalize_code_review_payload(raw: RawCodeReviewPayload) -> Option<CodeReviewPayload> {
    let findings = raw
        .findings
        .into_iter()
        .filter_map(|finding| {
            let title = finding.title.trim();
            let body = finding.body.trim();
            if title.is_empty() || body.is_empty() {
                return None;
            }
            let (title, priority) = normalize_priority_and_title(title, finding.priority);
            Some(CodeReviewFinding {
                title,
                body: body.to_owned(),
                confidence_score: finding.confidence_score,
                priority,
                code_location: finding
                    .code_location
                    .map(|location| CodeReviewCodeLocation {
                        absolute_file_path: normalize_review_path(&location.absolute_file_path),
                        line_range: location.line_range.map(normalize_line_range),
                    }),
            })
        })
        .collect::<Vec<_>>();

    if findings.is_empty() {
        return None;
    }

    Some(CodeReviewPayload {
        findings,
        overall_correctness: raw.overall_correctness,
        overall_explanation: raw
            .overall_explanation
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty()),
        overall_confidence_score: raw.overall_confidence_score,
    })
}

fn parse_code_review_from_json_str(text: &str) -> Option<CodeReviewPayload> {
    let value = serde_json::from_str::<serde_json::Value>(text).ok()?;
    let raw = serde_json::from_value::<RawCodeReviewPayload>(value).ok()?;
    normalize_code_review_payload(raw)
}

fn extract_json_object_candidates(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut start_index = 0;
    let mut candidates = Vec::new();
    while let Some(relative_start) = text[start_index..].find('{') {
        let absolute_start = start_index + relative_start;
        let mut depth = 0_u32;
        let mut in_string = false;
        let mut is_escaped = false;
        for index in absolute_start..bytes.len() {
            let byte = bytes[index];
            if in_string {
                if is_escaped {
                    is_escaped = false;
                    continue;
                }
                match byte {
                    b'\\' => is_escaped = true,
                    b'"' => in_string = false,
                    _ => {}
                }
                continue;
            }

            match byte {
                b'"' => in_string = true,
                b'{' => depth += 1,
                b'}' => {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                    if depth == 0 {
                        candidates.push(text[absolute_start..=index].to_owned());
                        break;
                    }
                }
                _ => {}
            }
        }
        start_index = absolute_start + 1;
    }
    candidates
}

fn extract_fenced_json_candidates(text: &str) -> Vec<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut candidates = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        let trimmed = lines[index].trim();
        let Some(opening) = opening_fence(trimmed) else {
            index += 1;
            continue;
        };
        let language = trimmed[opening.marker.len_utf8() * opening.length..]
            .trim()
            .to_ascii_lowercase();
        let mut content_lines = Vec::new();
        let mut cursor = index + 1;
        while cursor < lines.len() {
            if is_closing_fence(lines[cursor].trim(), opening.marker, opening.length) {
                let content = content_lines.join("\n");
                if language.is_empty() || language == "json" {
                    let trimmed_content = content.trim();
                    if trimmed_content.starts_with('{') && trimmed_content.ends_with('}') {
                        candidates.push(trimmed_content.to_owned());
                    } else {
                        candidates.extend(extract_json_object_candidates(trimmed_content));
                    }
                }
                index = cursor;
                break;
            }
            content_lines.push(lines[cursor]);
            cursor += 1;
        }
        index += 1;
    }
    candidates
}

// ---------------------------------------------------------------------------
// Kind inference
// ---------------------------------------------------------------------------

impl ToolCallKind {
    fn from_title(title: &str) -> Self {
        let n = normalize_token(title);
        if n.contains("command output") {
            return Self::CommandOutput;
        }
        if n.contains("command execution") || n == "command" {
            return Self::CommandExecution;
        }
        if n.contains("file change") {
            return Self::FileChange;
        }
        if n.contains("file diff") || n == "diff" {
            return Self::FileDiff;
        }
        if n.contains("mcp tool progress") {
            return Self::McpToolProgress;
        }
        if n.contains("mcp tool call") || n == "mcp" {
            return Self::McpToolCall;
        }
        if n.contains("web search") {
            return Self::WebSearch;
        }
        if n.contains("collaboration") || n.contains("collab") {
            return Self::Collaboration;
        }
        if n.contains("image view") || n == "image" {
            return Self::ImageView;
        }
        if n.contains("widget") || n.contains("show widget") {
            return Self::Widget;
        }
        if n.contains("dynamic tool call") {
            return Self::McpToolCall;
        }
        // Additional keyword-based inference (task spec)
        if n.contains("read") || n.contains("write") || n.contains("edit") {
            return Self::FileChange;
        }
        if n.contains("run") || n.contains("execute") || n.contains("shell") {
            return Self::CommandExecution;
        }
        if n.contains("search") {
            return Self::WebSearch;
        }
        Self::Unknown(title.trim().to_owned())
    }

    /// Returns `true` when the kind was actually recognized from the title
    /// (i.e. not Unknown).
    fn is_recognized(&self) -> bool {
        !matches!(self, Self::Unknown(_))
    }
}

// ---------------------------------------------------------------------------
// Status inference
// ---------------------------------------------------------------------------

fn normalize_status(raw: &str) -> ToolCallStatus {
    let n = normalize_token(raw);
    match n.as_str() {
        "inprogress" | "in progress" | "running" | "pending" | "started" => {
            ToolCallStatus::InProgress
        }
        "completed" | "complete" | "success" | "ok" | "done" => ToolCallStatus::Completed,
        "failed" | "failure" | "error" | "denied" | "cancelled" | "aborted" => {
            ToolCallStatus::Failed
        }
        _ => ToolCallStatus::Unknown,
    }
}

fn inferred_status(kind: &ToolCallKind, raw: Option<&str>) -> ToolCallStatus {
    let s = normalize_status(raw.unwrap_or(""));
    if s != ToolCallStatus::Unknown {
        return s;
    }
    // Legacy web-search messages may lack status → treat as completed.
    if matches!(kind, ToolCallKind::WebSearch) {
        return ToolCallStatus::Completed;
    }
    ToolCallStatus::Unknown
}

// ---------------------------------------------------------------------------
// Duration parsing
// ---------------------------------------------------------------------------

fn parse_duration(raw: &str) -> Option<std::time::Duration> {
    let s = raw.trim().to_lowercase();
    if s.is_empty() {
        return None;
    }

    // "500ms"
    if let Some(ms) = s.strip_suffix("ms")
        && let Ok(v) = ms.trim().parse::<f64>() {
            return Some(std::time::Duration::from_secs_f64(v / 1000.0));
        }

    // "2.3s"
    if let Some(sec) = s.strip_suffix('s') {
        // Guard against "minutes" already stripped, etc.
        if !sec.ends_with("minute")
            && let Ok(v) = sec.trim().parse::<f64>() {
                return Some(std::time::Duration::from_secs_f64(v));
            }
    }

    // "1.5 minutes" / "1.5 minute"
    if let Some(mins) = s
        .strip_suffix("minutes")
        .or_else(|| s.strip_suffix("minute"))
        && let Ok(v) = mins.trim().parse::<f64>() {
            return Some(std::time::Duration::from_secs_f64(v * 60.0));
        }

    // "1m 30s" compound
    let mut total_secs: f64 = 0.0;
    let mut found = false;
    // minutes component
    if let Some(m_idx) = s.find('m') {
        let before = &s[..m_idx];
        // make sure it's not "ms"
        if s.as_bytes().get(m_idx + 1) != Some(&b's') {
            if let Ok(v) = before.trim().parse::<f64>() {
                total_secs += v * 60.0;
                found = true;
            }
            // seconds after 'm'
            let after = s[m_idx + 1..].trim();
            if let Some(sec) = after.strip_suffix('s')
                && let Ok(v) = sec.trim().parse::<f64>() {
                    total_secs += v;
                }
        }
    }
    if found {
        return Some(std::time::Duration::from_secs_f64(total_secs));
    }

    // Last resort: plain number → seconds
    if let Ok(v) = s.parse::<f64>() {
        return Some(std::time::Duration::from_secs_f64(v));
    }

    None
}

// ---------------------------------------------------------------------------
// Target parsing
// ---------------------------------------------------------------------------

fn parse_target(raw: &str) -> Option<ToolCallTarget> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    // "agent-name [role]"
    if s.ends_with(']')
        && let Some(bracket) = s.rfind('[') {
            let nickname = s[..bracket].trim();
            let role = &s[bracket + 1..s.len() - 1];
            if !nickname.is_empty() && !role.is_empty() {
                return Some(ToolCallTarget {
                    agent_nickname: Some(nickname.to_owned()),
                    role: Some(role.trim().to_owned()),
                    display_label: s.to_owned(),
                });
            }
        }
    Some(ToolCallTarget {
        agent_nickname: None,
        role: None,
        display_label: s.to_owned(),
    })
}

// ---------------------------------------------------------------------------
// Fence helpers
// ---------------------------------------------------------------------------

struct FenceOpening {
    marker: char,
    length: usize,
}

struct ParsedFence {
    language: String,
    content: String,
}

fn opening_fence(line: &str) -> Option<FenceOpening> {
    let first = line.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let length = line.chars().take_while(|&c| c == first).count();
    if length < 3 {
        return None;
    }
    Some(FenceOpening {
        marker: first,
        length,
    })
}

fn is_closing_fence(line: &str, marker: char, min_length: usize) -> bool {
    if !line.starts_with(marker) {
        return false;
    }
    let length = line.chars().take_while(|&c| c == marker).count();
    if length < min_length {
        return false;
    }
    line[marker.len_utf8() * length..].trim().is_empty()
}

struct FenceState {
    marker: char,
    length: usize,
}

fn update_fence_state(line: &str, state: &mut Option<FenceState>) {
    let trimmed = line.trim();
    if let Some(active) = state.as_ref() {
        if is_closing_fence(trimmed, active.marker, active.length) {
            *state = None;
        }
        return;
    }
    if let Some(opening) = opening_fence(trimmed) {
        *state = Some(FenceState {
            marker: opening.marker,
            length: opening.length,
        });
    }
}

fn parse_single_fence(text: &str) -> Option<ParsedFence> {
    let lines: Vec<&str> = text.split('\n').collect();
    let first = lines.first()?.trim();
    let opening = opening_fence(first)?;

    let mut collected = Vec::new();
    let mut closed = false;
    for &line in &lines[1..] {
        let trimmed = line.trim();
        if is_closing_fence(trimmed, opening.marker, opening.length) {
            closed = true;
            break;
        }
        collected.push(line);
    }
    if !closed {
        return None;
    }

    let language = first[opening.marker.len_utf8() * opening.length..]
        .trim()
        .to_owned();
    let content = collected.join("\n").trim_matches('\n').to_owned();
    Some(ParsedFence { language, content })
}

// ---------------------------------------------------------------------------
// Key-value / section header parsing
// ---------------------------------------------------------------------------

fn parse_key_value_line(line: &str) -> Option<(String, String)> {
    let sep = line.find(':')?;
    let key = line[..sep].trim().to_owned();
    let value = line[sep + 1..].trim().to_owned();
    if key.is_empty() {
        return None;
    }
    Some((key, value))
}

fn parse_section_header(line: &str) -> Option<(String, String)> {
    let (key, value) = parse_key_value_line(line)?;
    if is_named_section(&normalize_token(&key)) {
        Some((key, value))
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Target items
// ---------------------------------------------------------------------------

fn parse_target_items(content: &str) -> Vec<String> {
    let mut items = Vec::new();
    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let de_bulleted = BULLET_RE.replace(line, "");
        for candidate in de_bulleted.split(',') {
            let normalized = candidate.trim();
            if !normalized.is_empty() {
                items.push(normalized.to_owned());
            }
        }
    }
    items
}

// ---------------------------------------------------------------------------
// "Looks like JSON" heuristic
// ---------------------------------------------------------------------------

fn looks_like_json(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return false;
    }
    let first = trimmed.as_bytes()[0];
    if matches!(
        first,
        b'{' | b'[' | b'"' | b'-' | b'0'..=b'9' | b't' | b'f' | b'n'
    ) {
        serde_json::from_str::<serde_json::Value>(trimmed).is_ok()
    } else {
        false
    }
}

// ---------------------------------------------------------------------------
// Internal body representation
// ---------------------------------------------------------------------------

struct ParsedBody {
    metadata: Vec<(String, String)>,
    primary_sections: Vec<ToolCallSection>,
    aux_sections: Vec<ToolCallSection>,
    file_paths: Vec<String>,
}

impl ParsedBody {
    fn metadata_value(&self, key: &str) -> Option<&str> {
        let normalized = normalize_token(key);
        self.metadata
            .iter()
            .find(|(k, _)| normalize_token(k) == normalized)
            .map(|(_, v)| v.as_str())
    }
}

// ---------------------------------------------------------------------------
// System envelope
// ---------------------------------------------------------------------------

fn parse_system_envelope(text: &str) -> Option<(&str, &str)> {
    let trimmed = text.trim();
    if !trimmed.starts_with("### ") {
        return None;
    }
    let first_newline = trimmed.find('\n').unwrap_or(trimmed.len());
    let title = trimmed[4..first_newline].trim();
    if title.is_empty() {
        return None;
    }
    let body = trimmed[first_newline..].trim();
    Some((title, body))
}

// ---------------------------------------------------------------------------
// Section classification helpers
// ---------------------------------------------------------------------------

fn make_code_like(label: &str, content: &str, fallback_language: &str) -> ToolCallSection {
    if let Some(fence) = parse_single_fence(content) {
        let language = if fence.language.is_empty() {
            fallback_language.to_owned()
        } else {
            fence.language
        };
        return ToolCallSection {
            name: label.to_owned(),
            content: SectionContent::Code {
                language: Some(language),
                code: fence.content,
            },
        };
    }
    ToolCallSection {
        name: label.to_owned(),
        content: SectionContent::Code {
            language: Some(fallback_language.to_owned()),
            code: content.to_owned(),
        },
    }
}

fn make_json_like(label: &str, content: &str) -> ToolCallSection {
    if let Some(fence) = parse_single_fence(content) {
        let lang = normalize_token(&fence.language);
        if lang == "json" || lang.is_empty() {
            return ToolCallSection {
                name: label.to_owned(),
                content: match serde_json::from_str::<serde_json::Value>(&fence.content) {
                    Ok(v) => SectionContent::Json(v),
                    Err(_) => SectionContent::Text(fence.content),
                },
            };
        }
        if lang == "diff" {
            return ToolCallSection {
                name: label.to_owned(),
                content: SectionContent::Diff(fence.content),
            };
        }
        return ToolCallSection {
            name: label.to_owned(),
            content: SectionContent::Code {
                language: Some(fence.language),
                code: fence.content,
            },
        };
    }
    if looks_like_json(content) {
        return ToolCallSection {
            name: label.to_owned(),
            content: match serde_json::from_str::<serde_json::Value>(content) {
                Ok(v) => SectionContent::Json(v),
                Err(_) => SectionContent::Text(content.to_owned()),
            },
        };
    }
    ToolCallSection {
        name: label.to_owned(),
        content: SectionContent::Text(content.to_owned()),
    }
}

fn make_output_like(label: &str, content: &str) -> ToolCallSection {
    if let Some(fence) = parse_single_fence(content) {
        let lang = normalize_token(&fence.language);
        if lang == "diff" {
            return ToolCallSection {
                name: label.to_owned(),
                content: SectionContent::Diff(fence.content),
            };
        }
        if lang == "json" {
            return ToolCallSection {
                name: label.to_owned(),
                content: match serde_json::from_str::<serde_json::Value>(&fence.content) {
                    Ok(v) => SectionContent::Json(v),
                    Err(_) => SectionContent::Text(fence.content),
                },
            };
        }
        if lang == "text" || lang.is_empty() {
            return ToolCallSection {
                name: label.to_owned(),
                content: SectionContent::Text(fence.content),
            };
        }
        return ToolCallSection {
            name: label.to_owned(),
            content: SectionContent::Code {
                language: Some(fence.language),
                code: fence.content,
            },
        };
    }
    ToolCallSection {
        name: label.to_owned(),
        content: SectionContent::Text(content.to_owned()),
    }
}

// ---------------------------------------------------------------------------
// Split utilities
// ---------------------------------------------------------------------------

fn split_top_level(text: &str, separator: &str) -> Vec<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut chunks: Vec<String> = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    let mut fence_state: Option<FenceState> = None;

    let flush = |current: &mut Vec<&str>, chunks: &mut Vec<String>| {
        let content = current.join("\n");
        let trimmed = content.trim();
        if !trimmed.is_empty() {
            chunks.push(trimmed.to_owned());
        }
        current.clear();
    };

    for &line in &lines {
        let trimmed = line.trim();
        if fence_state.is_none() && trimmed == separator {
            flush(&mut current, &mut chunks);
            continue;
        }
        current.push(line);
        update_fence_state(line, &mut fence_state);
    }
    flush(&mut current, &mut chunks);
    chunks
}

struct RawSection {
    label: Option<String>,
    content: String,
}

fn split_named_sections(text: &str) -> Vec<RawSection> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut sections: Vec<RawSection> = Vec::new();
    let mut current_label: Option<String> = None;
    let mut buffer: Vec<String> = Vec::new();
    let mut saw_named_section = false;
    let mut fence_state: Option<FenceState> = None;

    let flush =
        |label: &mut Option<String>, buffer: &mut Vec<String>, sections: &mut Vec<RawSection>| {
            let content = buffer.join("\n");
            let trimmed = content.trim();
            if !trimmed.is_empty() || label.is_some() {
                sections.push(RawSection {
                    label: label.take(),
                    content: trimmed.to_owned(),
                });
            }
            buffer.clear();
        };

    for &line in &lines {
        let trimmed = line.trim();
        if fence_state.is_none()
            && let Some((label, inline_value)) = parse_section_header(trimmed) {
                saw_named_section = true;
                flush(&mut current_label, &mut buffer, &mut sections);
                current_label = Some(label);
                if !inline_value.is_empty() {
                    buffer.push(inline_value);
                }
                continue;
            }

        buffer.push(line.to_owned());
        update_fence_state(line, &mut fence_state);
    }
    flush(&mut current_label, &mut buffer, &mut sections);

    if !saw_named_section {
        let trimmed = text.trim();
        return vec![RawSection {
            label: None,
            content: trimmed.to_owned(),
        }];
    }

    sections
}

// ---------------------------------------------------------------------------
// File-change specific parsing
// ---------------------------------------------------------------------------

fn parse_file_change_sections(remainder: &str) -> (Vec<ToolCallSection>, Vec<String>) {
    let chunks = split_top_level(remainder, "---");
    let mut sections = Vec::new();
    let mut paths = Vec::new();

    for (idx, chunk) in chunks.iter().enumerate() {
        let lines: Vec<&str> = chunk.split('\n').collect();
        let mut cursor = 0;
        let mut entry_metadata: Vec<(String, String)> = Vec::new();

        while cursor < lines.len() {
            let trimmed = lines[cursor].trim();
            if trimmed.is_empty() {
                cursor += 1;
                break;
            }
            if let Some((key, value)) = parse_key_value_line(trimmed) {
                let nk = normalize_token(&key);
                if nk == "path" || nk == "kind" {
                    if nk == "path" && !value.is_empty() {
                        paths.push(value.clone());
                    }
                    entry_metadata.push((key, value));
                    cursor += 1;
                    continue;
                }
            }
            break;
        }

        if !entry_metadata.is_empty() {
            sections.push(ToolCallSection {
                name: format!("Change {}", idx + 1),
                content: SectionContent::KeyValue(entry_metadata),
            });
        }

        let content: String = lines[cursor..].join("\n");
        let content = content.trim();
        if content.is_empty() {
            continue;
        }
        if let Some(fence) = parse_single_fence(content) {
            let language = normalize_token(&fence.language);
            sections.push(ToolCallSection {
                name: if language == "diff" {
                    "Diff".to_owned()
                } else {
                    "Content".to_owned()
                },
                content: if language == "diff" {
                    SectionContent::Diff(fence.content)
                } else if language == "json" {
                    match serde_json::from_str::<serde_json::Value>(&fence.content) {
                        Ok(v) => SectionContent::Json(v),
                        Err(_) => SectionContent::Text(fence.content),
                    }
                } else if language == "text" || language.is_empty() {
                    SectionContent::Text(fence.content)
                } else {
                    SectionContent::Code {
                        language: Some(fence.language),
                        code: fence.content,
                    }
                },
            });
        } else {
            sections.push(ToolCallSection {
                name: "Content".to_owned(),
                content: SectionContent::Text(content.to_owned()),
            });
        }
    }

    (sections, paths)
}

// ---------------------------------------------------------------------------
// Section building
// ---------------------------------------------------------------------------

fn append_section(
    raw: RawSection,
    kind: &ToolCallKind,
    primary: &mut Vec<ToolCallSection>,
    aux: &mut Vec<ToolCallSection>,
) {
    let content = raw.content.trim();
    if content.is_empty() {
        return;
    }

    if let Some(ref label) = raw.label {
        let capitalized = capitalize_first(label);
        let nk = normalize_token(label);
        match nk.as_str() {
            "command" => {
                primary.push(make_code_like("Command", content, "bash"));
            }
            "arguments" => {
                primary.push(make_json_like("Arguments", content));
            }
            "result" => {
                primary.push(make_json_like("Result", content));
            }
            "output" => {
                primary.push(make_output_like("Output", content));
            }
            "action" => {
                primary.push(make_json_like("Action", content));
            }
            "prompt" => {
                primary.push(ToolCallSection {
                    name: "Prompt".to_owned(),
                    content: SectionContent::Text(content.to_owned()),
                });
            }
            "progress" => {
                let items: Vec<String> = content
                    .lines()
                    .map(|l| l.trim().to_owned())
                    .filter(|l| !l.is_empty())
                    .collect();
                if !items.is_empty() {
                    aux.push(ToolCallSection {
                        name: "Progress".to_owned(),
                        content: SectionContent::List(items),
                    });
                }
            }
            "targets" => {
                let items = parse_target_items(content);
                if !items.is_empty() {
                    aux.push(ToolCallSection {
                        name: "Targets".to_owned(),
                        content: SectionContent::List(items),
                    });
                } else {
                    primary.push(ToolCallSection {
                        name: "Targets".to_owned(),
                        content: SectionContent::Text(content.to_owned()),
                    });
                }
            }
            "error" => {
                primary.push(make_output_like("Error", content));
            }
            _ => {
                primary.push(ToolCallSection {
                    name: capitalized,
                    content: SectionContent::Text(content.to_owned()),
                });
            }
        }
        return;
    }

    // Unlabeled section: classify by kind
    match kind {
        ToolCallKind::CommandOutput => {
            primary.push(make_output_like("Output", content));
        }
        ToolCallKind::FileDiff => {
            if let Some(fence) = parse_single_fence(content) {
                if normalize_token(&fence.language) == "diff" {
                    primary.push(ToolCallSection {
                        name: "Diff".to_owned(),
                        content: SectionContent::Diff(fence.content),
                    });
                } else {
                    primary.push(ToolCallSection {
                        name: "Diff".to_owned(),
                        content: SectionContent::Diff(content.to_owned()),
                    });
                }
            } else {
                primary.push(ToolCallSection {
                    name: "Diff".to_owned(),
                    content: SectionContent::Diff(content.to_owned()),
                });
            }
        }
        ToolCallKind::McpToolProgress => {
            let items: Vec<String> = content
                .lines()
                .map(|l| l.trim().to_owned())
                .filter(|l| !l.is_empty())
                .collect();
            if !items.is_empty() {
                aux.push(ToolCallSection {
                    name: "Progress".to_owned(),
                    content: SectionContent::List(items),
                });
            }
        }
        _ => {
            if let Some(fence) = parse_single_fence(content) {
                let language = normalize_token(&fence.language);
                if language == "json" {
                    primary.push(ToolCallSection {
                        name: "Details".to_owned(),
                        content: match serde_json::from_str::<serde_json::Value>(&fence.content) {
                            Ok(v) => SectionContent::Json(v),
                            Err(_) => SectionContent::Text(fence.content),
                        },
                    });
                } else if language == "diff" {
                    primary.push(ToolCallSection {
                        name: "Diff".to_owned(),
                        content: SectionContent::Diff(fence.content),
                    });
                } else if language == "text" || language.is_empty() {
                    primary.push(ToolCallSection {
                        name: "Details".to_owned(),
                        content: SectionContent::Text(fence.content),
                    });
                } else {
                    primary.push(ToolCallSection {
                        name: "Details".to_owned(),
                        content: SectionContent::Code {
                            language: Some(fence.language),
                            code: fence.content,
                        },
                    });
                }
            } else {
                primary.push(ToolCallSection {
                    name: "Details".to_owned(),
                    content: SectionContent::Text(content.to_owned()),
                });
            }
        }
    }
}

fn capitalize_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        None => String::new(),
        Some(first) => {
            let mut out = first.to_uppercase().to_string();
            out.push_str(&s[first.len_utf8()..]);
            out
        }
    }
}

// ---------------------------------------------------------------------------
// Body parsing
// ---------------------------------------------------------------------------

fn parse_body(body: &str, kind: &ToolCallKind) -> ParsedBody {
    let lines: Vec<&str> = body.split('\n').collect();
    let mut index = 0;
    let mut metadata: Vec<(String, String)> = Vec::new();
    let mut file_paths: Vec<String> = Vec::new();
    let mut aux_sections: Vec<ToolCallSection> = Vec::new();

    // Parse leading metadata
    while index < lines.len() {
        let trimmed = lines[index].trim();
        if trimmed.is_empty() {
            if metadata.is_empty() {
                index += 1;
                continue;
            }
            index += 1;
            break;
        }
        if parse_section_header(trimmed).is_some() {
            break;
        }
        let Some((key, value)) = parse_key_value_line(trimmed) else {
            break;
        };
        let nk = normalize_token(&key);
        if !is_leading_key(&nk) {
            break;
        }

        if nk == "targets" {
            let mut target_content = value.clone();
            if target_content.trim().is_empty() {
                let mut cursor = index + 1;
                let mut extra_lines: Vec<&str> = Vec::new();
                while cursor < lines.len() {
                    let next_trimmed = lines[cursor].trim();
                    if next_trimmed.is_empty() || parse_section_header(next_trimmed).is_some() {
                        break;
                    }
                    extra_lines.push(next_trimmed);
                    cursor += 1;
                }
                if !extra_lines.is_empty() {
                    target_content = extra_lines.join("\n");
                    index = cursor - 1;
                }
            }
            let items = parse_target_items(&target_content);
            if !items.is_empty() {
                aux_sections.push(ToolCallSection {
                    name: "Targets".to_owned(),
                    content: SectionContent::List(items),
                });
            }
        } else {
            if nk == "path" && !value.is_empty() {
                file_paths.push(value.clone());
            }
            metadata.push((key, value));
        }
        index += 1;
    }

    let remainder: String = lines[index..].join("\n");
    let remainder = remainder.trim();
    let mut primary_sections: Vec<ToolCallSection> = Vec::new();

    if !remainder.is_empty() {
        match kind {
            ToolCallKind::FileChange => {
                let (secs, paths) = parse_file_change_sections(remainder);
                primary_sections.extend(secs);
                file_paths.extend(paths);
            }
            _ => {
                let raw_sections = split_named_sections(remainder);
                for raw in raw_sections {
                    append_section(raw, kind, &mut primary_sections, &mut aux_sections);
                }
            }
        }
    }

    // McpToolProgress fallback
    if matches!(kind, ToolCallKind::McpToolProgress)
        && aux_sections.is_empty()
        && !remainder.is_empty()
    {
        let items: Vec<String> = remainder
            .lines()
            .map(|l| l.trim().to_owned())
            .filter(|l| !l.is_empty())
            .collect();
        if !items.is_empty() {
            aux_sections.push(ToolCallSection {
                name: "Progress".to_owned(),
                content: SectionContent::List(items),
            });
        }
    }

    ParsedBody {
        metadata,
        primary_sections,
        aux_sections,
        file_paths,
    }
}

// ---------------------------------------------------------------------------
// Summary generation
// ---------------------------------------------------------------------------

fn strip_shell_wrapper(command: &str) -> String {
    let value = command.trim();
    let wrappers = ["/bin/zsh -lc '", "/bin/bash -lc '"];
    for wrapper in wrappers {
        if value.starts_with(wrapper) && value.ends_with('\'') {
            return value[wrapper.len()..value.len() - 1].to_owned();
        }
    }
    value.to_owned()
}

fn command_summary(sections: &[ToolCallSection]) -> Option<String> {
    for section in sections {
        let is_command = normalize_token(&section.name) == "command";
        if !is_command {
            continue;
        }
        let text = match &section.content {
            SectionContent::Code { code, .. } => code.as_str(),
            SectionContent::Text(t) => t.as_str(),
            _ => continue,
        };
        let first_line = text.lines().map(|l| l.trim()).find(|l| !l.is_empty());
        if let Some(line) = first_line {
            return Some(line.to_owned());
        }
    }
    None
}

fn collaboration_target_summary(body: &ParsedBody) -> Option<String> {
    for section in &body.aux_sections {
        if normalize_token(&section.name) != "targets" {
            continue;
        }
        if let SectionContent::List(ref items) = section.content {
            let first = items.first()?;
            if items.len() > 1 {
                return Some(format!("{} +{}", first, items.len() - 1));
            }
            return Some(first.clone());
        }
    }
    None
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn summary_for(
    kind: &ToolCallKind,
    title: &str,
    _status: &ToolCallStatus,
    _duration: Option<&std::time::Duration>,
    body: &ParsedBody,
) -> Option<String> {
    match kind {
        ToolCallKind::CommandExecution | ToolCallKind::CommandOutput => {
            if let Some(cmd) = command_summary(&body.primary_sections) {
                return Some(strip_shell_wrapper(&cmd));
            }
        }
        ToolCallKind::FileChange | ToolCallKind::FileDiff => {
            if let Some(first) = body.file_paths.first() {
                let base = basename(first);
                if body.file_paths.len() > 1 {
                    return Some(format!("{} +{} files", base, body.file_paths.len() - 1));
                }
                return Some(if base.is_empty() {
                    first.clone()
                } else {
                    base.to_owned()
                });
            }
        }
        ToolCallKind::McpToolCall | ToolCallKind::McpToolProgress => {
            if let Some(tool) = body.metadata_value("tool")
                && !tool.is_empty() {
                    return Some(tool.to_owned());
                }
        }
        ToolCallKind::WebSearch => {
            if let Some(query) = body.metadata_value("query")
                && !query.is_empty() {
                    return Some(query.to_owned());
                }
        }
        ToolCallKind::ImageView => {
            if let Some(path) = body.metadata_value("path")
                && !path.is_empty() {
                    let base = basename(path);
                    return Some(if base.is_empty() {
                        path.to_owned()
                    } else {
                        base.to_owned()
                    });
                }
        }
        ToolCallKind::Collaboration => {
            if let Some(ts) = collaboration_target_summary(body)
                && !ts.is_empty() {
                    return Some(ts);
                }
            if let Some(tool) = body.metadata_value("tool")
                && !tool.is_empty() {
                    return Some(tool.to_owned());
                }
        }
        ToolCallKind::Widget => {}
        ToolCallKind::Unknown(_) => {}
    }

    // Fallback: use title
    Some(title.to_owned())
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parse a message that may contain Codex findings JSON into a normalized
/// code-review payload.
pub fn parse_code_review_message(text: &str) -> Option<CodeReviewPayload> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }

    if trimmed.starts_with('{') && trimmed.ends_with('}')
        && let Some(parsed) = parse_code_review_from_json_str(trimmed) {
            return Some(parsed);
        }

    for candidate in extract_fenced_json_candidates(trimmed) {
        if let Some(parsed) = parse_code_review_from_json_str(&candidate) {
            return Some(parsed);
        }
    }

    for candidate in extract_json_object_candidates(trimmed) {
        if let Some(parsed) = parse_code_review_from_json_str(&candidate) {
            return Some(parsed);
        }
    }

    None
}

/// Parse a markdown-structured system message into zero or more typed tool
/// call cards.
///
/// A single message may contain multiple `### <Title>` blocks; each one
/// produces a separate `ToolCallCard`. Non-tool-call content is silently
/// skipped.
pub fn parse_tool_call_message(text: &str) -> Vec<ToolCallCard> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    // Split on top-level `### ` headers, respecting code fences.
    let blocks = split_h3_blocks(trimmed);
    let mut cards = Vec::new();

    for block in blocks {
        if let Some(card) = parse_single_block(&block) {
            cards.push(card);
        }
    }

    cards
}

/// Split text into blocks at `### ` boundaries, respecting code fences.
fn split_h3_blocks(text: &str) -> Vec<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut blocks: Vec<String> = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    let mut fence_state: Option<FenceState> = None;

    for &line in &lines {
        let trimmed = line.trim();
        if fence_state.is_none() && trimmed.starts_with("### ") && !current.is_empty() {
            let content = current.join("\n");
            let c = content.trim();
            if !c.is_empty() {
                blocks.push(c.to_owned());
            }
            current.clear();
        }
        current.push(line);
        update_fence_state(line, &mut fence_state);
    }
    if !current.is_empty() {
        let content = current.join("\n");
        let c = content.trim();
        if !c.is_empty() {
            blocks.push(c.to_owned());
        }
    }
    blocks
}

fn parse_single_block(text: &str) -> Option<ToolCallCard> {
    let (title, body) = parse_system_envelope(text)?;
    let kind = ToolCallKind::from_title(title);

    // If the kind is Unknown and the body is empty, skip.
    if !kind.is_recognized() && body.is_empty() {
        return None;
    }
    if body.is_empty() {
        return None;
    }

    let parsed = parse_body(body, &kind);

    // If everything is empty, skip for recognized kinds too.
    if parsed.metadata.is_empty()
        && parsed.primary_sections.is_empty()
        && parsed.aux_sections.is_empty()
    {
        return None;
    }

    let status = inferred_status(&kind, parsed.metadata_value("status"));
    let duration = parsed.metadata_value("duration").and_then(parse_duration);

    // Build target from first target in aux sections
    let target = parsed
        .aux_sections
        .iter()
        .find(|s| normalize_token(&s.name) == "targets")
        .and_then(|s| match &s.content {
            SectionContent::List(items) => items.first().and_then(|i| parse_target(i)),
            _ => None,
        });

    let summary = summary_for(&kind, title, &status, duration.as_ref(), &parsed);

    // Build final sections list
    let mut all_sections: Vec<ToolCallSection> = Vec::new();
    if !parsed.metadata.is_empty() {
        all_sections.push(ToolCallSection {
            name: "Metadata".to_owned(),
            content: SectionContent::KeyValue(parsed.metadata),
        });
    }
    all_sections.extend(parsed.primary_sections);
    all_sections.extend(parsed.aux_sections);

    Some(ToolCallCard {
        kind,
        title: title.to_owned(),
        summary,
        status,
        duration,
        target,
        sections: all_sections,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_code_review_json() -> String {
        serde_json::json!({
            "findings": [
                {
                    "title": "[P1] Fall back to turn/start when queue sync fails",
                    "body": "A queued follow-up can get stuck indefinitely.",
                    "confidence_score": 0.97,
                    "priority": 1,
                    "code_location": {
                        "absolute_file_path": "/Users/sigkitten/dev/litter/shared/rust-bridge/codex-mobile-client/src/mobile_client_impl.rs",
                        "line_range": { "start": 799, "end": 815 }
                    }
                }
            ],
            "overall_correctness": "incorrect",
            "overall_explanation": "There are blocking issues.",
            "overall_confidence_score": 0.92
        })
        .to_string()
    }

    // -- normalize_token --

    #[test]
    fn test_normalize_token() {
        assert_eq!(normalize_token("  Hello World  "), "hello world");
        assert_eq!(normalize_token("Exit Code"), "exit code");
        assert_eq!(normalize_token("MCP-Tool_Call!"), "mcp tool call");
        assert_eq!(normalize_token(""), "");
    }

    #[test]
    fn parse_code_review_message_accepts_raw_json() {
        let parsed =
            parse_code_review_message(&sample_code_review_json()).expect("should parse findings");
        assert_eq!(parsed.findings.len(), 1);
        assert_eq!(
            parsed.findings[0].title,
            "Fall back to turn/start when queue sync fails"
        );
        assert_eq!(parsed.findings[0].priority, Some(1));
        assert_eq!(
            parsed.findings[0]
                .code_location
                .as_ref()
                .map(|location| location.absolute_file_path.as_str()),
            Some(
                "/Users/sigkitten/dev/litter/shared/rust-bridge/codex-mobile-client/src/mobile_client_impl.rs"
            )
        );
        assert_eq!(parsed.overall_correctness.as_deref(), Some("incorrect"));
    }

    #[test]
    fn parse_code_review_message_accepts_fenced_json() {
        let message = format!("```json\n{}\n```", sample_code_review_json());
        let parsed = parse_code_review_message(&message).expect("should parse fenced findings");
        assert_eq!(parsed.findings.len(), 1);
    }

    #[test]
    fn parse_code_review_message_accepts_embedded_json() {
        let message = format!(
            "Here are the findings:\n\n{}\n\nPlease fix them.",
            sample_code_review_json()
        );
        let parsed = parse_code_review_message(&message).expect("should parse embedded findings");
        assert_eq!(parsed.findings[0].priority, Some(1));
    }

    #[test]
    fn parse_code_review_message_rejects_invalid_json() {
        assert!(parse_code_review_message("{\"findings\": [}").is_none());
        assert!(parse_code_review_message("plain markdown response").is_none());
    }

    #[test]
    fn normalize_priority_and_title_strips_title_prefix() {
        let parsed = parse_code_review_message(
            r#"{"findings":[{"title":"[P2] Preserve resume overrides","body":"Bug body","confidence_score":0.7,"code_location":{"absolute_file_path":"/tmp/file.rs","line_range":{"start":10,"end":12}}}]}"#,
        )
        .expect("should parse findings");
        assert_eq!(parsed.findings[0].title, "Preserve resume overrides");
        assert_eq!(parsed.findings[0].priority, Some(2));
    }

    #[test]
    fn normalize_review_path_matches_desktop_style() {
        assert_eq!(
            normalize_review_path(r#"\\?\C:\repo\src\main.rs"#),
            "/mnt/c/repo/src/main.rs"
        );
        assert_eq!(
            normalize_review_path("//wsl$/Ubuntu/home/sig/project/src/lib.rs"),
            "/home/sig/project/src/lib.rs"
        );
        assert_eq!(
            normalize_review_path("//wsl.localhost/Ubuntu/home/sig/project/src/lib.rs"),
            "/home/sig/project/src/lib.rs"
        );
        assert_eq!(
            normalize_review_path("/Users/sigkitten/dev/litter/src/main.rs"),
            "/Users/sigkitten/dev/litter/src/main.rs"
        );
    }

    #[test]
    fn normalize_line_range_preserves_single_and_multi_line_ranges() {
        let single = normalize_line_range(RawCodeReviewLineRange { start: 12, end: 12 });
        assert_eq!(single, CodeReviewLineRange { start: 12, end: 12 });

        let multi = normalize_line_range(RawCodeReviewLineRange { start: 10, end: 15 });
        assert_eq!(multi, CodeReviewLineRange { start: 10, end: 15 });
    }

    // -- kind inference --

    #[test]
    fn test_kind_from_title_exact() {
        assert_eq!(
            ToolCallKind::from_title("Command Execution"),
            ToolCallKind::CommandExecution
        );
        assert_eq!(
            ToolCallKind::from_title("Command Output"),
            ToolCallKind::CommandOutput
        );
        assert_eq!(
            ToolCallKind::from_title("File Change"),
            ToolCallKind::FileChange
        );
        assert_eq!(
            ToolCallKind::from_title("File Diff"),
            ToolCallKind::FileDiff
        );
        assert_eq!(
            ToolCallKind::from_title("MCP Tool Call"),
            ToolCallKind::McpToolCall
        );
        assert_eq!(
            ToolCallKind::from_title("MCP Tool Progress"),
            ToolCallKind::McpToolProgress
        );
        assert_eq!(
            ToolCallKind::from_title("Web Search"),
            ToolCallKind::WebSearch
        );
        assert_eq!(
            ToolCallKind::from_title("Collaboration"),
            ToolCallKind::Collaboration
        );
        assert_eq!(
            ToolCallKind::from_title("Image View"),
            ToolCallKind::ImageView
        );
        assert_eq!(ToolCallKind::from_title("Widget"), ToolCallKind::Widget);
    }

    #[test]
    fn test_kind_from_title_shorthand() {
        assert_eq!(
            ToolCallKind::from_title("command"),
            ToolCallKind::CommandExecution
        );
        assert_eq!(ToolCallKind::from_title("diff"), ToolCallKind::FileDiff);
        assert_eq!(ToolCallKind::from_title("mcp"), ToolCallKind::McpToolCall);
        assert_eq!(ToolCallKind::from_title("image"), ToolCallKind::ImageView);
        assert_eq!(
            ToolCallKind::from_title("collab"),
            ToolCallKind::Collaboration
        );
    }

    #[test]
    fn test_kind_from_title_keyword_inference() {
        assert_eq!(
            ToolCallKind::from_title("Read file"),
            ToolCallKind::FileChange
        );
        assert_eq!(
            ToolCallKind::from_title("Write output"),
            ToolCallKind::FileChange
        );
        assert_eq!(
            ToolCallKind::from_title("Edit config"),
            ToolCallKind::FileChange
        );
        assert_eq!(
            ToolCallKind::from_title("Run tests"),
            ToolCallKind::CommandExecution
        );
        assert_eq!(
            ToolCallKind::from_title("Execute script"),
            ToolCallKind::CommandExecution
        );
        assert_eq!(
            ToolCallKind::from_title("Shell command"),
            ToolCallKind::CommandExecution
        );
        assert_eq!(
            ToolCallKind::from_title("Search results"),
            ToolCallKind::WebSearch
        );
    }

    #[test]
    fn test_kind_unknown() {
        assert_eq!(
            ToolCallKind::from_title("Magical Unicorn"),
            ToolCallKind::Unknown("Magical Unicorn".to_owned())
        );
    }

    #[test]
    fn test_kind_dynamic_tool_call() {
        assert_eq!(
            ToolCallKind::from_title("Dynamic Tool Call"),
            ToolCallKind::McpToolCall
        );
    }

    // -- status --

    #[test]
    fn test_normalize_status() {
        assert_eq!(normalize_status("completed"), ToolCallStatus::Completed);
        assert_eq!(normalize_status("Complete"), ToolCallStatus::Completed);
        assert_eq!(normalize_status("SUCCESS"), ToolCallStatus::Completed);
        assert_eq!(normalize_status("ok"), ToolCallStatus::Completed);
        assert_eq!(normalize_status("done"), ToolCallStatus::Completed);

        assert_eq!(normalize_status("in progress"), ToolCallStatus::InProgress);
        assert_eq!(normalize_status("InProgress"), ToolCallStatus::InProgress);
        assert_eq!(normalize_status("running"), ToolCallStatus::InProgress);
        assert_eq!(normalize_status("pending"), ToolCallStatus::InProgress);
        assert_eq!(normalize_status("started"), ToolCallStatus::InProgress);

        assert_eq!(normalize_status("failed"), ToolCallStatus::Failed);
        assert_eq!(normalize_status("FAILURE"), ToolCallStatus::Failed);
        assert_eq!(normalize_status("error"), ToolCallStatus::Failed);
        assert_eq!(normalize_status("denied"), ToolCallStatus::Failed);
        assert_eq!(normalize_status("cancelled"), ToolCallStatus::Failed);
        assert_eq!(normalize_status("aborted"), ToolCallStatus::Failed);

        assert_eq!(normalize_status(""), ToolCallStatus::Unknown);
        assert_eq!(normalize_status("banana"), ToolCallStatus::Unknown);
    }

    #[test]
    fn test_web_search_defaults_completed() {
        let status = inferred_status(&ToolCallKind::WebSearch, None);
        assert_eq!(status, ToolCallStatus::Completed);
    }

    // -- duration parsing --

    #[test]
    fn test_parse_duration_seconds() {
        let d = parse_duration("2.3s").unwrap();
        assert!((d.as_secs_f64() - 2.3).abs() < 0.001);
    }

    #[test]
    fn test_parse_duration_milliseconds() {
        let d = parse_duration("500ms").unwrap();
        assert!((d.as_secs_f64() - 0.5).abs() < 0.001);
    }

    #[test]
    fn test_parse_duration_minutes() {
        let d = parse_duration("1.5 minutes").unwrap();
        assert!((d.as_secs_f64() - 90.0).abs() < 0.001);
    }

    #[test]
    fn test_parse_duration_compound() {
        let d = parse_duration("1m 30s").unwrap();
        assert!((d.as_secs_f64() - 90.0).abs() < 0.001);
    }

    #[test]
    fn test_parse_duration_empty() {
        assert!(parse_duration("").is_none());
        assert!(parse_duration("   ").is_none());
    }

    // -- target parsing --

    #[test]
    fn test_parse_target_with_role() {
        let t = parse_target("agent-name [researcher]").unwrap();
        assert_eq!(t.agent_nickname.as_deref(), Some("agent-name"));
        assert_eq!(t.role.as_deref(), Some("researcher"));
        assert_eq!(t.display_label, "agent-name [researcher]");
    }

    #[test]
    fn test_parse_target_plain() {
        let t = parse_target("plain-agent").unwrap();
        assert!(t.agent_nickname.is_none());
        assert!(t.role.is_none());
        assert_eq!(t.display_label, "plain-agent");
    }

    #[test]
    fn test_parse_target_empty() {
        assert!(parse_target("").is_none());
        assert!(parse_target("   ").is_none());
    }

    // -- fence helpers --

    #[test]
    fn test_parse_single_fence_backtick() {
        let text = "```python\nprint('hello')\n```";
        let f = parse_single_fence(text).unwrap();
        assert_eq!(f.language, "python");
        assert_eq!(f.content, "print('hello')");
    }

    #[test]
    fn test_parse_single_fence_tilde() {
        let text = "~~~json\n{\"key\": 1}\n~~~";
        let f = parse_single_fence(text).unwrap();
        assert_eq!(f.language, "json");
        assert_eq!(f.content, "{\"key\": 1}");
    }

    #[test]
    fn test_parse_single_fence_no_language() {
        let text = "```\nsome text\n```";
        let f = parse_single_fence(text).unwrap();
        assert_eq!(f.language, "");
        assert_eq!(f.content, "some text");
    }

    #[test]
    fn test_parse_single_fence_unclosed() {
        let text = "```python\nprint('hello')";
        assert!(parse_single_fence(text).is_none());
    }

    #[test]
    fn test_parse_single_fence_longer_fence() {
        let text = "````\ninner ``` fence\n````";
        let f = parse_single_fence(text).unwrap();
        assert_eq!(f.content, "inner ``` fence");
    }

    // -- key-value parsing --

    #[test]
    fn test_parse_key_value_line() {
        let (k, v) = parse_key_value_line("Status: Completed").unwrap();
        assert_eq!(k, "Status");
        assert_eq!(v, "Completed");
    }

    #[test]
    fn test_parse_key_value_line_empty_key() {
        assert!(parse_key_value_line(": value").is_none());
    }

    #[test]
    fn test_parse_key_value_line_no_colon() {
        assert!(parse_key_value_line("no colon here").is_none());
    }

    // -- target items --

    #[test]
    fn test_parse_target_items_bullets() {
        let content = "- alpha\n- beta, gamma\n* delta";
        let items = parse_target_items(content);
        assert_eq!(items, vec!["alpha", "beta", "gamma", "delta"]);
    }

    // -- looks_like_json --

    #[test]
    fn test_looks_like_json() {
        assert!(looks_like_json("{\"a\": 1}"));
        assert!(looks_like_json("[1,2,3]"));
        assert!(looks_like_json("\"hello\""));
        assert!(looks_like_json("42"));
        assert!(looks_like_json("true"));
        assert!(looks_like_json("null"));
        assert!(!looks_like_json(""));
        assert!(!looks_like_json("hello world"));
    }

    // -- system envelope --

    #[test]
    fn test_parse_system_envelope_basic() {
        let (title, body) = parse_system_envelope("### My Title\nsome body").unwrap();
        assert_eq!(title, "My Title");
        assert_eq!(body, "some body");
    }

    #[test]
    fn test_parse_system_envelope_no_body() {
        let (title, body) = parse_system_envelope("### Title Only").unwrap();
        assert_eq!(title, "Title Only");
        assert_eq!(body, "");
    }

    #[test]
    fn test_parse_system_envelope_not_header() {
        assert!(parse_system_envelope("## Wrong level").is_none());
        assert!(parse_system_envelope("plain text").is_none());
    }

    #[test]
    fn test_parse_system_envelope_empty_title() {
        assert!(parse_system_envelope("### ").is_none());
    }

    // -- strip_shell_wrapper --

    #[test]
    fn test_strip_shell_wrapper() {
        assert_eq!(strip_shell_wrapper("/bin/zsh -lc 'ls -la'"), "ls -la");
        assert_eq!(strip_shell_wrapper("/bin/bash -lc 'echo hi'"), "echo hi");
        assert_eq!(strip_shell_wrapper("plain command"), "plain command");
    }

    // -- full parse_tool_call_message tests --

    #[test]
    fn test_empty_input() {
        assert!(parse_tool_call_message("").is_empty());
        assert!(parse_tool_call_message("   ").is_empty());
    }

    #[test]
    fn test_non_tool_message() {
        assert!(parse_tool_call_message("Hello, world!").is_empty());
        assert!(parse_tool_call_message("## Not a tool call\nstuff").is_empty());
    }

    #[test]
    fn test_simple_command_execution() {
        let text = "\
### Command Execution
Status: Completed
Duration: 1.5s

Command: ls -la
Output:
```
total 42
drwxr-xr-x 5 user group 160 Jan  1 00:00 .
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::CommandExecution);
        assert_eq!(card.title, "Command Execution");
        assert_eq!(card.status, ToolCallStatus::Completed);
        assert!(card.duration.is_some());
        assert!((card.duration.unwrap().as_secs_f64() - 1.5).abs() < 0.001);
        assert_eq!(card.summary.as_deref(), Some("ls -la"));
    }

    #[test]
    fn test_command_execution_with_shell_wrapper() {
        let text = "\
### Command Execution
Status: Completed

Command: /bin/zsh -lc 'npm test'";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].summary.as_deref(), Some("npm test"));
    }

    #[test]
    fn test_file_change() {
        let text = "\
### File Change
Status: Completed
Path: src/main.rs
Kind: edit

```diff
-old line
+new line
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::FileChange);
        assert_eq!(card.summary.as_deref(), Some("main.rs"));
    }

    #[test]
    fn test_file_change_multiple_files() {
        let text = "\
### File Change
Status: Completed

Path: src/a.rs
Kind: edit

```diff
-old
+new
```

---

Path: src/b.rs
Kind: create

```diff
+added
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::FileChange);
        assert_eq!(card.summary.as_deref(), Some("a.rs +1 files"));
    }

    #[test]
    fn test_mcp_tool_call() {
        let text = "\
### MCP Tool Call
Status: Completed
Tool: my_custom_tool

Arguments:
```json
{\"key\": \"value\"}
```

Result:
```json
{\"result\": 42}
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::McpToolCall);
        assert_eq!(card.summary.as_deref(), Some("my_custom_tool"));
        // Should have Metadata + Arguments + Result sections
        assert!(card.sections.len() >= 3);
    }

    #[test]
    fn test_web_search() {
        let text = "\
### Web Search
Query: rust async patterns

Result:
```json
{\"results\": [{\"title\": \"Async Rust\"}]}
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::WebSearch);
        assert_eq!(card.status, ToolCallStatus::Completed);
        assert_eq!(card.summary.as_deref(), Some("rust async patterns"));
    }

    #[test]
    fn test_collaboration_with_targets() {
        let text = "\
### Collaboration
Status: Completed
Tool: delegate
Targets:
- agent-1 [researcher]
- agent-2 [coder]

Result: done";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::Collaboration);
        // Summary should be the first target
        assert_eq!(card.summary.as_deref(), Some("agent-1 [researcher] +1"));
        // Should have a target parsed from the list
        assert!(card.target.is_some());
        let target = card.target.as_ref().unwrap();
        assert_eq!(target.agent_nickname.as_deref(), Some("agent-1"));
        assert_eq!(target.role.as_deref(), Some("researcher"));
    }

    #[test]
    fn test_image_view() {
        let text = "\
### Image View
Status: Completed
Path: /tmp/screenshot.png";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].kind, ToolCallKind::ImageView);
        assert_eq!(cards[0].summary.as_deref(), Some("screenshot.png"));
    }

    #[test]
    fn test_mcp_tool_progress() {
        let text = "\
### MCP Tool Progress
Status: In Progress
Tool: long_running

Step 1 complete
Step 2 in progress";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::McpToolProgress);
        assert_eq!(card.status, ToolCallStatus::InProgress);
        assert_eq!(card.summary.as_deref(), Some("long_running"));
    }

    #[test]
    fn test_failed_status() {
        let text = "\
### Command Execution
Status: Failed

Error:
```
permission denied
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].status, ToolCallStatus::Failed);
    }

    #[test]
    fn test_file_diff() {
        let text = "\
### File Diff
Status: Completed
Path: src/lib.rs

```diff
-old code
+new code
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.kind, ToolCallKind::FileDiff);
        // The diff section should be present
        let has_diff = card
            .sections
            .iter()
            .any(|s| matches!(&s.content, SectionContent::Diff(_)));
        assert!(has_diff);
    }

    #[test]
    fn test_multiple_tools_in_one_message() {
        let text = "\
### Command Execution
Status: Completed

Command: echo hello

### File Change
Status: Completed
Path: src/main.rs

```diff
+hello
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 2);
        assert_eq!(cards[0].kind, ToolCallKind::CommandExecution);
        assert_eq!(cards[1].kind, ToolCallKind::FileChange);
    }

    #[test]
    fn test_code_fence_inside_does_not_split() {
        let text = "\
### Command Output
Status: Completed

Output:
```
### This is not a header
It is inside a code fence
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].kind, ToolCallKind::CommandOutput);
    }

    #[test]
    fn test_tilde_fence() {
        let text = "\
### Command Execution
Status: Completed

Command:
~~~bash
ls -la
~~~";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let cmd_section = cards[0].sections.iter().find(|s| s.name == "Command");
        assert!(cmd_section.is_some());
        match &cmd_section.unwrap().content {
            SectionContent::Code { language, code } => {
                assert_eq!(language.as_deref(), Some("bash"));
                assert_eq!(code, "ls -la");
            }
            _ => panic!("Expected Code section"),
        }
    }

    #[test]
    fn test_unknown_kind_with_body() {
        let text = "\
### Magical Unicorn
Status: Completed

Details: something happened";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        assert_eq!(
            cards[0].kind,
            ToolCallKind::Unknown("Magical Unicorn".to_owned())
        );
    }

    #[test]
    fn test_widget() {
        let text = "\
### Widget
Status: Completed

Action:
```json
{\"type\": \"chart\", \"data\": [1,2,3]}
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].kind, ToolCallKind::Widget);
    }

    #[test]
    fn test_malformed_no_body() {
        let text = "### Command Execution";
        let cards = parse_tool_call_message(text);
        assert!(cards.is_empty());
    }

    #[test]
    fn test_malformed_empty_body() {
        let text = "### Command Execution\n\n\n";
        let cards = parse_tool_call_message(text);
        assert!(cards.is_empty());
    }

    #[test]
    fn test_json_arguments_section() {
        let text = "\
### MCP Tool Call
Status: Completed
Tool: query_db

Arguments:
```json
{\"sql\": \"SELECT 1\"}
```

Result: ok";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let args_section = cards[0].sections.iter().find(|s| s.name == "Arguments");
        assert!(args_section.is_some());
        match &args_section.unwrap().content {
            SectionContent::Json(v) => {
                assert_eq!(v["sql"], "SELECT 1");
            }
            _ => panic!("Expected Json section"),
        }
    }

    #[test]
    fn test_output_with_diff_language() {
        let text = "\
### Command Execution
Status: Completed

Output:
```diff
-removed
+added
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let output_section = cards[0].sections.iter().find(|s| s.name == "Output");
        assert!(output_section.is_some());
        assert!(matches!(
            &output_section.unwrap().content,
            SectionContent::Diff(_)
        ));
    }

    #[test]
    fn test_duration_varieties() {
        // Test that all duration formats from the spec work end-to-end
        for (input, expected_secs) in [
            ("2.3s", 2.3),
            ("500ms", 0.5),
            ("1m 30s", 90.0),
            ("1.5 minutes", 90.0),
        ] {
            let text = format!(
                "### Command Execution\nStatus: Completed\nDuration: {}\n\nCommand: echo hi",
                input
            );
            let cards = parse_tool_call_message(&text);
            assert_eq!(cards.len(), 1, "Failed for duration: {}", input);
            let d = cards[0].duration.unwrap();
            assert!(
                (d.as_secs_f64() - expected_secs).abs() < 0.01,
                "Duration mismatch for '{}': got {} expected {}",
                input,
                d.as_secs_f64(),
                expected_secs
            );
        }
    }

    #[test]
    fn test_exit_code_metadata() {
        let text = "\
### Command Execution
Status: Failed
Exit Code: 1

Output:
```
error: something went wrong
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.status, ToolCallStatus::Failed);
        // Metadata section should contain exit code
        let meta = card.sections.iter().find(|s| s.name == "Metadata");
        assert!(meta.is_some());
        match &meta.unwrap().content {
            SectionContent::KeyValue(entries) => {
                let exit_code = entries
                    .iter()
                    .find(|(k, _)| normalize_token(k) == "exit code");
                assert!(exit_code.is_some());
                assert_eq!(exit_code.unwrap().1, "1");
            }
            _ => panic!("Expected KeyValue"),
        }
    }

    #[test]
    fn test_three_tools_streaming() {
        let text = "\
### Command Execution
Status: Completed

Command: cargo check

### File Change
Status: Completed
Path: src/main.rs

```diff
+new line
```

### Web Search
Query: rust error handling best practices

Result: Some results here";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 3);
        assert_eq!(cards[0].kind, ToolCallKind::CommandExecution);
        assert_eq!(cards[1].kind, ToolCallKind::FileChange);
        assert_eq!(cards[2].kind, ToolCallKind::WebSearch);
    }

    #[test]
    fn test_nested_fences() {
        let text = "\
### Command Output
Status: Completed

Output:
````
Here is some output with a nested fence:
```python
print('hello')
```
End of output
````";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let output = cards[0].sections.iter().find(|s| s.name == "Output");
        assert!(output.is_some());
        match &output.unwrap().content {
            SectionContent::Text(t) => {
                assert!(t.contains("```python"));
                assert!(t.contains("print('hello')"));
            }
            _ => panic!("Expected Text section for nested fences"),
        }
    }

    #[test]
    fn test_error_section() {
        let text = "\
### Command Execution
Status: Failed

Error:
```
/bin/sh: command not found
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let err = cards[0].sections.iter().find(|s| s.name == "Error");
        assert!(err.is_some());
    }

    #[test]
    fn test_prompt_section() {
        let text = "\
### Collaboration
Status: Completed
Tool: delegate

Prompt: Please research this topic

Targets:
- agent-1 [researcher]";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let prompt = cards[0].sections.iter().find(|s| s.name == "Prompt");
        assert!(prompt.is_some());
        match &prompt.unwrap().content {
            SectionContent::Text(t) => assert_eq!(t, "Please research this topic"),
            _ => panic!("Expected Text"),
        }
    }

    #[test]
    fn test_file_change_with_separator() {
        let text = "\
### File Change
Status: Completed

Path: src/a.rs
Kind: edit

```diff
-old
+new
```

---

Path: src/b.rs
Kind: create

```diff
+added
```";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];

        // Should have Change 1 metadata, Diff, Change 2 metadata, Diff
        let change_sections: Vec<_> = card
            .sections
            .iter()
            .filter(|s| s.name.starts_with("Change"))
            .collect();
        assert_eq!(change_sections.len(), 2);

        let diff_sections: Vec<_> = card
            .sections
            .iter()
            .filter(|s| matches!(&s.content, SectionContent::Diff(_)))
            .collect();
        assert_eq!(diff_sections.len(), 2);
    }

    #[test]
    fn test_approval_metadata() {
        let text = "\
### Command Execution
Status: Completed
Approval: auto-approved

Command: echo hello";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let meta = cards[0].sections.iter().find(|s| s.name == "Metadata");
        assert!(meta.is_some());
        match &meta.unwrap().content {
            SectionContent::KeyValue(entries) => {
                let approval = entries
                    .iter()
                    .find(|(k, _)| normalize_token(k) == "approval");
                assert!(approval.is_some());
                assert_eq!(approval.unwrap().1, "auto-approved");
            }
            _ => panic!("Expected KeyValue"),
        }
    }

    #[test]
    fn test_directory_metadata() {
        let text = "\
### Command Execution
Status: Completed
Directory: /home/user/project

Command: pwd";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
    }

    #[test]
    fn test_inline_json_no_fence() {
        let text = "\
### MCP Tool Call
Status: Completed
Tool: test

Arguments: {\"key\": \"value\"}";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        // Arguments becomes a named section with inline value
        // The parser should recognize the JSON
    }

    #[test]
    fn test_command_output_unlabeled() {
        let text = "\
### Command Output
Status: Completed

hello world
more output";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        // Unlabeled content for CommandOutput → Output section
        let output = card.sections.iter().find(|s| s.name == "Output");
        assert!(output.is_some());
    }

    #[test]
    fn test_file_diff_unlabeled() {
        let text = "\
### File Diff
Status: Completed

-old line
+new line";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let has_diff = cards[0]
            .sections
            .iter()
            .any(|s| matches!(&s.content, SectionContent::Diff(_)));
        assert!(has_diff);
    }

    #[test]
    fn test_show_widget_title() {
        assert_eq!(
            ToolCallKind::from_title("Show Widget"),
            ToolCallKind::Widget
        );
    }

    #[test]
    fn test_targets_multiline_metadata() {
        let text = "\
### Collaboration
Status: Completed
Targets:
- agent-a [planner]
- agent-b [executor]

Result: all done";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let targets = cards[0].sections.iter().find(|s| s.name == "Targets");
        assert!(targets.is_some());
        match &targets.unwrap().content {
            SectionContent::List(items) => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0], "agent-a [planner]");
                assert_eq!(items[1], "agent-b [executor]");
            }
            _ => panic!("Expected List"),
        }
    }

    #[test]
    fn test_progress_section() {
        let text = "\
### MCP Tool Progress
Status: In Progress
Tool: long_task

Progress:
Step 1 done
Step 2 in progress
Step 3 pending";
        let cards = parse_tool_call_message(text);
        assert_eq!(cards.len(), 1);
        let progress = cards[0].sections.iter().find(|s| s.name == "Progress");
        assert!(progress.is_some());
        match &progress.unwrap().content {
            SectionContent::List(items) => {
                assert_eq!(items.len(), 3);
            }
            _ => panic!("Expected List for progress"),
        }
    }
}
