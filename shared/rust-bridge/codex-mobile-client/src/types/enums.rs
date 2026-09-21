//! Mobile-owned enums that do not come directly from upstream protocol types.

use codex_app_server_protocol as upstream;
use serde::{Deserialize, Serialize};

/// Opaque agent identifier — the stable lowercase name that alleycat
/// advertises for an agent (`"codex"`, `"claude"`, `"hermes"`, …). All
/// UI labels, icons, and capability flags come from
/// [`crate::store::AgentMetadataStore`] keyed off this id. Litter does
/// not maintain a typed enum so the only place anyone adds a new agent
/// is the alleycat manifest.
pub type AgentRuntimeKind = String;

/// Canonical default agent id used when a record carried no explicit
/// agent. Keeps Serde `default` callers happy; real records resolve
/// their actual id through probe metadata or thread routing.
pub fn default_agent_runtime_kind() -> AgentRuntimeKind {
    "codex".to_owned()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppSortDirection {
    Asc,
    Desc,
}

impl From<AppSortDirection> for upstream::SortDirection {
    fn from(value: AppSortDirection) -> Self {
        match value {
            AppSortDirection::Asc => Self::Asc,
            AppSortDirection::Desc => Self::Desc,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppThreadSortKey {
    CreatedAt,
    UpdatedAt,
}

impl From<AppThreadSortKey> for upstream::ThreadSortKey {
    fn from(value: AppThreadSortKey) -> Self {
        match value {
            AppThreadSortKey::CreatedAt => Self::CreatedAt,
            AppThreadSortKey::UpdatedAt => Self::UpdatedAt,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppThreadSourceKind {
    Cli,
    VsCode,
    Exec,
    AppServer,
    SubAgent,
    SubAgentReview,
    SubAgentCompact,
    SubAgentThreadSpawn,
    SubAgentOther,
    Unknown,
}

impl From<AppThreadSourceKind> for upstream::ThreadSourceKind {
    fn from(value: AppThreadSourceKind) -> Self {
        match value {
            AppThreadSourceKind::Cli => Self::Cli,
            AppThreadSourceKind::VsCode => Self::VsCode,
            AppThreadSourceKind::Exec => Self::Exec,
            AppThreadSourceKind::AppServer => Self::AppServer,
            AppThreadSourceKind::SubAgent => Self::SubAgent,
            AppThreadSourceKind::SubAgentReview => Self::SubAgentReview,
            AppThreadSourceKind::SubAgentCompact => Self::SubAgentCompact,
            AppThreadSourceKind::SubAgentThreadSpawn => Self::SubAgentThreadSpawn,
            AppThreadSourceKind::SubAgentOther => Self::SubAgentOther,
            AppThreadSourceKind::Unknown => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppThreadGoalStatus {
    Active,
    Paused,
    Blocked,
    UsageLimited,
    BudgetLimited,
    Complete,
}

impl From<upstream::ThreadGoalStatus> for AppThreadGoalStatus {
    fn from(value: upstream::ThreadGoalStatus) -> Self {
        match value {
            upstream::ThreadGoalStatus::Active => Self::Active,
            upstream::ThreadGoalStatus::Paused => Self::Paused,
            upstream::ThreadGoalStatus::Blocked => Self::Blocked,
            upstream::ThreadGoalStatus::UsageLimited => Self::UsageLimited,
            upstream::ThreadGoalStatus::BudgetLimited => Self::BudgetLimited,
            upstream::ThreadGoalStatus::Complete => Self::Complete,
        }
    }
}

impl From<AppThreadGoalStatus> for upstream::ThreadGoalStatus {
    fn from(value: AppThreadGoalStatus) -> Self {
        match value {
            AppThreadGoalStatus::Active => Self::Active,
            AppThreadGoalStatus::Paused => Self::Paused,
            AppThreadGoalStatus::Blocked => Self::Blocked,
            AppThreadGoalStatus::UsageLimited => Self::UsageLimited,
            AppThreadGoalStatus::BudgetLimited => Self::BudgetLimited,
            AppThreadGoalStatus::Complete => Self::Complete,
        }
    }
}

/// Summary status of a thread for mobile thread lists and local state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ThreadSummaryStatus {
    NotLoaded,
    Idle,
    Active,
    SystemError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppModeKind {
    Default,
    Plan,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum AppPlanStepStatus {
    Pending,
    InProgress,
    Completed,
}

impl From<upstream::ThreadStatus> for ThreadSummaryStatus {
    fn from(value: upstream::ThreadStatus) -> Self {
        match value {
            upstream::ThreadStatus::NotLoaded => ThreadSummaryStatus::NotLoaded,
            upstream::ThreadStatus::Idle => ThreadSummaryStatus::Idle,
            upstream::ThreadStatus::Active { .. } => ThreadSummaryStatus::Active,
            upstream::ThreadStatus::SystemError => ThreadSummaryStatus::SystemError,
        }
    }
}

impl From<codex_app_server_protocol::TurnPlanStepStatus> for AppPlanStepStatus {
    fn from(value: codex_app_server_protocol::TurnPlanStepStatus) -> Self {
        match value {
            codex_app_server_protocol::TurnPlanStepStatus::Pending => Self::Pending,
            codex_app_server_protocol::TurnPlanStepStatus::InProgress => Self::InProgress,
            codex_app_server_protocol::TurnPlanStepStatus::Completed => Self::Completed,
        }
    }
}

/// Kind of approval being requested from the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ApprovalKind {
    Command,
    FileChange,
    Permissions,
    McpElicitation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ApprovalDecisionValue {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppOperationStatus {
    Unknown,
    Pending,
    InProgress,
    Completed,
    Failed,
    Declined,
    Interrupted,
}

impl AppOperationStatus {
    pub fn from_raw(raw: &str) -> Self {
        let trimmed = raw.trim();
        match trimmed {
            "pending" | "Pending" => Self::Pending,
            "inProgress" | "InProgress" => Self::InProgress,
            "completed" | "Completed" => Self::Completed,
            "failed" | "Failed" => Self::Failed,
            "declined" | "Declined" => Self::Declined,
            "interrupted" | "Interrupted" => Self::Interrupted,
            _ => {
                let normalized = trimmed.to_ascii_lowercase().replace(['_', ' '], "");
                match normalized.as_str() {
                    "pending" | "queued" => Self::Pending,
                    "inprogress" | "running" | "active" | "progress" => Self::InProgress,
                    "completed" | "complete" | "done" | "success" | "ok" | "succeeded" => {
                        Self::Completed
                    }
                    "failed" | "fail" | "error" | "errored" | "denied" => Self::Failed,
                    "declined" | "rejected" => Self::Declined,
                    "interrupted" | "cancelled" | "canceled" => Self::Interrupted,
                    _ => Self::Unknown,
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppSubagentStatus {
    Unknown,
    PendingInit,
    Running,
    Interrupted,
    Completed,
    Errored,
    Shutdown,
}

impl AppSubagentStatus {
    pub fn from_raw(raw: &str) -> Self {
        let trimmed = raw.trim();
        match trimmed {
            "pendingInit" | "PendingInit" => Self::PendingInit,
            "running" | "Running" => Self::Running,
            "interrupted" | "Interrupted" => Self::Interrupted,
            "completed" | "Completed" => Self::Completed,
            "errored" | "Errored" => Self::Errored,
            "shutdown" | "Shutdown" => Self::Shutdown,
            "notFound" | "NotFound" => Self::Unknown,
            _ => {
                let normalized = trimmed.to_ascii_lowercase().replace('_', "");
                match normalized.as_str() {
                    "pendinginit" | "pending" => Self::PendingInit,
                    "running" | "inprogress" | "active" | "thinking" => Self::Running,
                    "interrupted" => Self::Interrupted,
                    "completed" | "complete" | "done" | "idle" => Self::Completed,
                    "errored" | "error" | "failed" => Self::Errored,
                    "shutdown" => Self::Shutdown,
                    _ => Self::Unknown,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thread_status_roundtrip() {
        for status in [
            ThreadSummaryStatus::NotLoaded,
            ThreadSummaryStatus::Idle,
            ThreadSummaryStatus::Active,
            ThreadSummaryStatus::SystemError,
        ] {
            let json = serde_json::to_string(&status).unwrap();
            let deserialized: ThreadSummaryStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(status, deserialized);
        }
    }

    #[test]
    fn approval_kind_roundtrip() {
        for kind in [
            ApprovalKind::Command,
            ApprovalKind::FileChange,
            ApprovalKind::Permissions,
            ApprovalKind::McpElicitation,
        ] {
            let json = serde_json::to_string(&kind).unwrap();
            let deserialized: ApprovalKind = serde_json::from_str(&json).unwrap();
            assert_eq!(kind, deserialized);
        }
    }

    #[test]
    fn thread_status_serializes_camel_case() {
        assert_eq!(
            serde_json::to_value(&ThreadSummaryStatus::NotLoaded).unwrap(),
            serde_json::json!("notLoaded")
        );
        assert_eq!(
            serde_json::to_value(&ThreadSummaryStatus::SystemError).unwrap(),
            serde_json::json!("systemError")
        );
    }

    #[test]
    fn thread_status_from_upstream() {
        let mobile: ThreadSummaryStatus = upstream::ThreadStatus::Idle.into();
        assert_eq!(mobile, ThreadSummaryStatus::Idle);

        let mobile: ThreadSummaryStatus = upstream::ThreadStatus::Active {
            active_flags: vec![],
        }
        .into();
        assert_eq!(mobile, ThreadSummaryStatus::Active);
    }

    #[test]
    fn operation_status_normalizes_aliases() {
        assert_eq!(
            AppOperationStatus::from_raw("pending"),
            AppOperationStatus::Pending
        );
        assert_eq!(
            AppOperationStatus::from_raw("in_progress"),
            AppOperationStatus::InProgress
        );
        assert_eq!(
            AppOperationStatus::from_raw("done"),
            AppOperationStatus::Completed
        );
        assert_eq!(
            AppOperationStatus::from_raw("denied"),
            AppOperationStatus::Failed
        );
        assert_eq!(
            AppOperationStatus::from_raw("rejected"),
            AppOperationStatus::Declined
        );
    }

    #[test]
    fn subagent_status_normalizes_aliases() {
        assert_eq!(
            AppSubagentStatus::from_raw("PendingInit"),
            AppSubagentStatus::PendingInit
        );
        assert_eq!(
            AppSubagentStatus::from_raw("in_progress"),
            AppSubagentStatus::Running
        );
        assert_eq!(
            AppSubagentStatus::from_raw("done"),
            AppSubagentStatus::Completed
        );
        assert_eq!(
            AppSubagentStatus::from_raw("failed"),
            AppSubagentStatus::Errored
        );
        assert_eq!(
            AppSubagentStatus::from_raw("notFound"),
            AppSubagentStatus::Unknown
        );
    }
}
