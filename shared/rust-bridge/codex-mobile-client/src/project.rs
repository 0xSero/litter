//! Project model: `(server_id, cwd)` pairs derived from thread history.
//!
//! Pure functions — no runtime state, no storage. A "project" is simply a
//! unique `(server_id, cwd)` key surfaced from the session summaries.

use std::collections::HashMap;

use crate::store::boundary::AppSessionSummary;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppProject {
    pub id: String,
    pub server_id: String,
    pub cwd: String,
    pub last_used_at_ms: Option<i64>,
}

fn canonical_cwd(cwd: &str) -> String {
    canonical_cwd_opt(cwd).unwrap_or_else(|| cwd.trim().to_string())
}

fn canonical_cwd_opt(cwd: &str) -> Option<String> {
    let normalized = crate::remote_path::normalize_thread_cwd(cwd)?;
    let is_windows = crate::remote_path::RemotePath::parse(&normalized).is_windows();
    let trimmed = if is_windows {
        trim_trailing_windows_separator(&normalized)
    } else {
        normalized.trim_end_matches('/').to_string()
    };
    if trimmed.is_empty() {
        Some("/".to_string())
    } else {
        Some(trimmed)
    }
}

fn trim_trailing_windows_separator(path: &str) -> String {
    let mut trimmed = path.to_string();
    while trimmed.len() > 3 && trimmed.ends_with('\\') {
        trimmed.pop();
    }
    trimmed
}

/// Stable composite key; platforms use this to look up a specific project.
#[uniffi::export]
pub fn project_id_for(server_id: String, cwd: String) -> String {
    format!("{}::{}", server_id, canonical_cwd(&cwd))
}

/// Last path component, stripped of trailing slashes, for a default label.
#[uniffi::export]
pub fn project_default_label(cwd: String) -> String {
    let canon = canonical_cwd(&cwd);
    if crate::remote_path::RemotePath::parse(&canon).is_windows() {
        return canon
            .rsplit('\\')
            .find(|segment| !segment.is_empty())
            .map(|s| s.to_string())
            .unwrap_or(canon);
    }
    canon
        .rsplit('/')
        .find(|segment| !segment.is_empty())
        .map(|s| s.to_string())
        .unwrap_or(canon)
}

/// Derive the project list from thread history.
///
/// Sort: most-recently-used first, then stable by `(server_id, cwd)`.
#[uniffi::export]
pub fn derive_projects(sessions: Vec<AppSessionSummary>) -> Vec<AppProject> {
    let mut by_id: HashMap<String, AppProject> = HashMap::new();

    for summary in sessions {
        let Some(cwd) = canonical_cwd_opt(&summary.cwd) else {
            continue;
        };
        let server_id = summary.key.server_id.clone();
        let id = project_id_for(server_id.clone(), cwd.clone());
        let entry = by_id.entry(id.clone()).or_insert_with(|| AppProject {
            id: id.clone(),
            server_id,
            cwd,
            last_used_at_ms: None,
        });
        if let Some(ts) = summary.updated_at {
            if entry.last_used_at_ms.map_or(true, |prev| ts > prev) {
                entry.last_used_at_ms = Some(ts);
            }
        }
    }

    let mut projects: Vec<AppProject> = by_id.into_values().collect();
    projects.sort_by(|a, b| {
        b.last_used_at_ms
            .unwrap_or(i64::MIN)
            .cmp(&a.last_used_at_ms.unwrap_or(i64::MIN))
            .then(a.server_id.cmp(&b.server_id))
            .then(a.cwd.cmp(&b.cwd))
    });
    projects
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{AppSubagentStatus, ThreadKey};

    fn session(
        server: &str,
        thread: &str,
        cwd: &str,
        updated_at: Option<i64>,
    ) -> AppSessionSummary {
        AppSessionSummary {
            key: ThreadKey {
                server_id: server.to_string(),
                thread_id: thread.to_string(),
            },
            agent_runtime_kind: "codex".to_string(),
            server_display_name: server.to_string(),
            server_host: "".into(),
            title: "".into(),
            preview: "".into(),
            cwd: cwd.to_string(),
            model: "".into(),
            model_provider: "".into(),
            parent_thread_id: None,
            forked_from_id: None,
            agent_nickname: None,
            agent_role: None,
            agent_display_label: None,
            agent_status: AppSubagentStatus::Unknown,
            updated_at,
            has_active_turn: false,
            is_resumed: false,
            is_subagent: false,
            is_fork: false,
            last_response_preview: None,
            last_response_turn_id: None,
            last_user_message: None,
            last_tool_label: None,
            recent_tool_log: vec![],
            last_turn_start_ms: None,
            last_turn_end_ms: None,
            stats: None,
            token_usage: None,
            goal: None,
        }
    }

    #[test]
    fn derives_unique_projects_from_sessions() {
        let sessions = vec![
            session("srv1", "t1", "/a/b", Some(10)),
            session("srv1", "t2", "/a/b/", Some(20)), // same cwd, trailing slash
            session("srv2", "t3", "/a/b", Some(5)),
        ];
        let projects = derive_projects(sessions);
        assert_eq!(projects.len(), 2);
        // Most-recently-used first.
        assert_eq!(projects[0].server_id, "srv1");
        assert_eq!(projects[0].cwd, "/a/b");
        assert_eq!(projects[0].last_used_at_ms, Some(20));
    }

    #[test]
    fn default_label_takes_last_component() {
        assert_eq!(project_default_label("/a/b/c".into()), "c");
        assert_eq!(project_default_label("/a/b/c/".into()), "c");
        assert_eq!(project_default_label("/".into()), "/");
        assert_eq!(project_default_label(r"C:\Users\npace".into()), "npace");
        assert_eq!(project_default_label(r"C:\Users\npace\dev".into()), "dev");
    }

    #[test]
    fn derives_projects_with_normalized_windows_cwd() {
        let sessions = vec![
            session("srv1", "t1", r"C:\Users\npace\Users\npace", Some(10)),
            session("srv1", "t2", r"C:\Users\npace", Some(20)),
        ];
        let projects = derive_projects(sessions);
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].cwd, r"C:\Users\npace");
        assert_eq!(projects[0].last_used_at_ms, Some(20));
    }

    #[test]
    fn empty_cwd_sessions_are_ignored() {
        let sessions = vec![session("srv1", "t1", "", Some(10))];
        let projects = derive_projects(sessions);
        assert!(projects.is_empty());
    }

    #[test]
    fn unexpanded_home_fragment_sessions_are_ignored() {
        let sessions = vec![session("srv1", "t1", r"Users\npace", Some(10))];
        let projects = derive_projects(sessions);
        assert!(projects.is_empty());
    }

    #[test]
    fn sort_stable_when_timestamps_missing() {
        let sessions = vec![
            session("srv1", "t1", "/b", None),
            session("srv1", "t2", "/a", None),
        ];
        let projects = derive_projects(sessions);
        assert_eq!(projects.len(), 2);
        assert_eq!(projects[0].cwd, "/a");
        assert_eq!(projects[1].cwd, "/b");
    }
}
