//! Hydrated conversation types — the single public UniFFI surface for
//! conversation items. These are produced directly by `conversation.rs`
//! hydration from upstream typed protocol objects.

use crate::types::AppMessagePhase;
use crate::types::{AppOperationStatus, AppSubagentStatus};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedConversationItem {
    pub id: String,
    pub content: HydratedConversationItemContent,
    pub source_turn_id: Option<String>,
    pub source_turn_index: Option<u32>,
    pub timestamp: Option<f64>,
    pub is_from_user_turn_boundary: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Enum)]
pub enum HydratedConversationItemContent {
    User(HydratedUserMessageData),
    Assistant(HydratedAssistantMessageData),
    CodeReview(HydratedCodeReviewData),
    Reasoning(HydratedReasoningData),
    TodoList(HydratedTodoListData),
    ProposedPlan(HydratedProposedPlanData),
    CommandExecution(HydratedCommandExecutionData),
    FileChange(HydratedFileChangeData),
    TurnDiff(HydratedTurnDiffData),
    McpToolCall(HydratedMcpToolCallData),
    DynamicToolCall(HydratedDynamicToolCallData),
    MultiAgentAction(HydratedMultiAgentActionData),
    WebSearch(HydratedWebSearchData),
    ImageView(HydratedImageViewData),
    Widget(HydratedWidgetData),
    UserInputResponse(HydratedUserInputResponseData),
    Divider(HydratedDividerData),
    Error(HydratedErrorData),
    Note(HydratedNoteData),
    ImageGeneration(HydratedImageGenerationData),
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedUserMessageData {
    pub text: String,
    pub image_data_uris: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedAssistantMessageData {
    pub text: String,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub phase: Option<AppMessagePhase>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedCodeReviewData {
    pub findings: Vec<HydratedCodeReviewFindingData>,
    pub overall_correctness: Option<String>,
    pub overall_explanation: Option<String>,
    pub overall_confidence_score: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedCodeReviewFindingData {
    pub title: String,
    pub body: String,
    pub confidence_score: f64,
    pub priority: Option<u8>,
    pub code_location: Option<HydratedCodeReviewCodeLocationData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedCodeReviewCodeLocationData {
    pub absolute_file_path: String,
    pub line_range: Option<HydratedCodeReviewLineRangeData>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, uniffi::Record)]
pub struct HydratedCodeReviewLineRangeData {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedReasoningData {
    pub summary: Vec<String>,
    pub content: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedTodoListData {
    pub steps: Vec<HydratedPlanStep>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, uniffi::Enum)]
pub enum HydratedPlanStepStatus {
    Pending,
    InProgress,
    Completed,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedPlanStep {
    pub step: String,
    pub status: HydratedPlanStepStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedProposedPlanData {
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedCommandExecutionData {
    pub command: String,
    pub cwd: String,
    pub status: AppOperationStatus,
    pub output: Option<String>,
    pub exit_code: Option<i32>,
    pub duration_ms: Option<i64>,
    pub process_id: Option<String>,
    pub actions: Vec<HydratedCommandActionData>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, uniffi::Enum)]
pub enum HydratedCommandActionKind {
    Read,
    Search,
    ListFiles,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedCommandActionData {
    pub kind: HydratedCommandActionKind,
    pub command: String,
    pub name: Option<String>,
    pub path: Option<String>,
    pub query: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedFileChangeEntryData {
    pub path: String,
    pub kind: String,
    pub diff: String,
    pub additions: u32,
    pub deletions: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedFileChangeData {
    pub status: AppOperationStatus,
    pub changes: Vec<HydratedFileChangeEntryData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedTurnDiffData {
    pub diff: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedMcpToolCallData {
    pub server: String,
    pub tool: String,
    pub status: AppOperationStatus,
    pub duration_ms: Option<i64>,
    pub arguments_json: Option<String>,
    pub content_summary: Option<String>,
    pub structured_content_json: Option<String>,
    pub raw_output_json: Option<String>,
    pub error_message: Option<String>,
    pub progress_messages: Vec<String>,
    pub computer_use: Option<ComputerUseView>,
}

/// Typed variants for the 9 tools exposed by the `computer-use` MCP server
/// (list_apps, get_app_state, click, perform_secondary_action, scroll, drag,
/// type_text, press_key, set_value).
#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Enum)]
pub enum ComputerUseTool {
    ListApps,
    GetAppState {
        app: String,
    },
    /// `click` accepts either `element_index` or `{x, y}` pixel coordinates.
    Click {
        app: String,
        element_index: Option<String>,
        x: Option<f64>,
        y: Option<f64>,
        button: Option<String>,
    },
    PerformSecondaryAction {
        app: String,
        element_index: Option<String>,
        action: Option<String>,
    },
    Scroll {
        app: String,
        element_index: Option<String>,
        direction: Option<String>,
        pages: Option<f64>,
    },
    Drag {
        app: String,
        from_x: Option<f64>,
        from_y: Option<f64>,
        to_x: Option<f64>,
        to_y: Option<f64>,
    },
    TypeText {
        app: String,
        text: String,
    },
    PressKey {
        app: String,
        key: String,
    },
    SetValue {
        app: String,
        element_index: Option<String>,
        value: Option<String>,
    },
    Unknown {
        name: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct ComputerUseView {
    pub tool: ComputerUseTool,
    pub summary: String,
    /// PNG bytes. Decoded from the upstream base64 result in Rust so platforms
    /// receive ready-to-display `Data` / `ByteArray` with no per-platform
    /// base64 work.
    pub screenshot_png: Option<Vec<u8>>,
    pub accessibility_text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedToolMetadataData {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedDynamicToolDisplayData {
    pub title: String,
    pub summary: String,
    pub metadata: Vec<HydratedToolMetadataData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedDynamicToolCallData {
    pub namespace: Option<String>,
    pub tool: String,
    pub status: AppOperationStatus,
    pub duration_ms: Option<i64>,
    pub success: Option<bool>,
    pub arguments_json: Option<String>,
    pub content_summary: Option<String>,
    pub display: Option<HydratedDynamicToolDisplayData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedMultiAgentStateData {
    pub target_id: String,
    pub status: AppSubagentStatus,
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedMultiAgentActionData {
    pub tool: String,
    pub status: AppOperationStatus,
    pub prompt: Option<String>,
    pub targets: Vec<String>,
    pub receiver_thread_ids: Vec<String>,
    pub agent_states: Vec<HydratedMultiAgentStateData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedWebSearchData {
    pub query: String,
    pub action_json: Option<String>,
    pub is_in_progress: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedImageViewData {
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedWidgetData {
    pub title: String,
    pub widget_html: String,
    pub width: f64,
    pub height: f64,
    pub status: String,
    pub is_finalized: bool,
    /// Model-chosen slug identifying this app across regenerations in
    /// the origin thread. `None` when the `show_widget` call omitted it
    /// (pre-R2 widgets still in the timeline). Platforms use this to
    /// surface the "Saved as <slug>" chip on finalized bubbles.
    pub app_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedUserInputResponseOptionData {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedUserInputResponseQuestionData {
    pub id: String,
    pub header: Option<String>,
    pub question: String,
    pub answer: String,
    pub options: Vec<HydratedUserInputResponseOptionData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedUserInputResponseData {
    pub questions: Vec<HydratedUserInputResponseQuestionData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Enum)]
pub enum HydratedDividerData {
    ContextCompaction {
        is_complete: bool,
    },
    ModelRerouted {
        from_model: Option<String>,
        to_model: String,
        reason: Option<String>,
    },
    ReviewEntered {
        review: String,
    },
    ReviewExited {
        review: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedNoteData {
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedErrorData {
    pub title: String,
    pub message: String,
    pub details: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct HydratedImageGenerationData {
    pub status: AppOperationStatus,
    pub revised_prompt: Option<String>,
    /// Decoded PNG bytes from the upstream base64 `result` payload. `None`
    /// while the model is still streaming or when decoding fails.
    pub image_png: Option<Vec<u8>>,
    pub saved_path: Option<String>,
}
