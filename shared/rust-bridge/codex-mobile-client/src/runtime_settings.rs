//! Runtime-scoped native settings boundary shared by Swift and Kotlin.
use crate::types::AgentRuntimeKind;
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeSettingValueKind {
    Boolean,
    Number,
    String,
    Json,
}
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeSettingDescriptor {
    pub key: String,
    pub label: String,
    pub value_json: String,
    pub value_kind: RuntimeSettingValueKind,
    pub choices: Vec<String>,
    pub scope: String,
    pub source: String,
    pub writable: bool,
    pub read_only_reason: Option<String>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct RuntimeSettingsSnapshot {
    pub runtime_kind: AgentRuntimeKind,
    pub settings: Vec<RuntimeSettingDescriptor>,
}
fn sensitive(key: &str) -> bool {
    let key = key.to_ascii_lowercase().replace(['_', '-'], "");
    key.split('.').any(|part| part == "token" || part == "auth")
        || [
            "apikey",
            "secret",
            "password",
            "credential",
            "authorization",
            "accesstoken",
            "refreshtoken",
            "bearer",
            "headers",
            "env",
        ]
        .iter()
        .any(|part| key.contains(part))
}
fn has_sensitive(value: &Value) -> bool {
    match value {
        Value::Object(map) => map.iter().any(|(k, v)| sensitive(k) || has_sensitive(v)),
        Value::Array(items) => items.iter().any(has_sensitive),
        _ => false,
    }
}
pub fn validate_edit(key: &str, value: &Value) -> Result<(), String> {
    if key.is_empty() || key.starts_with('_') || sensitive(key) || has_sensitive(value) {
        Err("Credential or invalid settings cannot be edited here".into())
    } else {
        Ok(())
    }
}
pub fn snapshot(
    runtime_kind: AgentRuntimeKind,
    response: Value,
) -> Result<RuntimeSettingsSnapshot, String> {
    let config = response
        .get("config")
        .ok_or("Missing native configuration response")?;
    let mut settings = if let Some(metadata) = config.get("_litterSettings") {
        serde_json::from_value::<Vec<RuntimeSettingDescriptor>>(metadata.clone())
            .map_err(|e| e.to_string())?
    } else {
        let mut out = Vec::new();
        // Codex implements actual config writes. Older adapters did not; fail closed.
        describe(config, "", runtime_kind == "codex", &mut out);
        out
    };
    settings.retain(|setting| {
        !sensitive(&setting.key)
            && serde_json::from_str::<Value>(&setting.value_json).is_ok_and(|v| !has_sensitive(&v))
    });
    if runtime_kind == "codex" {
        apply_codex_constraints(&mut settings, &response);
    }
    settings.sort_by(|a, b| a.key.cmp(&b.key));
    Ok(RuntimeSettingsSnapshot {
        runtime_kind,
        settings,
    })
}
fn apply_codex_constraints(settings: &mut [RuntimeSettingDescriptor], response: &Value) {
    for setting in settings {
        if let Some(origin) =
            response
                .get("origins")
                .and_then(Value::as_object)
                .and_then(|origins| {
                    origins
                        .iter()
                        .filter(|(key, _)| {
                            setting.key == **key || setting.key.starts_with(&format!("{key}."))
                        })
                        .max_by_key(|(key, _)| key.len())
                        .map(|(_, v)| v)
                })
        {
            let kind = origin["name"]["type"].as_str().unwrap_or("unknown");
            setting.scope = origin["name"]["profile"]
                .as_str()
                .map(|profile| format!("profile {profile}"))
                .unwrap_or_else(|| kind.into());
            setting.source = origin["name"]["file"].as_str().unwrap_or(kind).into();
            if !matches!(kind, "user" | "packagedDefaults")
                || origin["name"]["profile"].as_str().is_some()
            {
                setting.writable = false;
                setting.read_only_reason = Some(format!(
                    "Effective value comes from the {kind} layer; edit that source or its policy"
                ));
            }
        }
        let requirements = &response["_requirements"]["requirements"];
        if (setting.key == "approval_policy" || setting.key.starts_with("approval_policy."))
            && requirements["allowedApprovalPolicies"]
                .as_array()
                .is_some_and(|values| {
                    values.iter().any(|value| !value.is_string())
                        || setting.key.starts_with("approval_policy.")
                })
        {
            setting.writable = false;
            setting.read_only_reason = Some(
                "Managed structured approval policies must be edited in native Codex settings"
                    .into(),
            );
        }
        let allowed = match setting.key.as_str() {
            "approval_policy" => Some("allowedApprovalPolicies"),
            "sandbox_mode" => Some("allowedSandboxModes"),
            "web_search" => Some("allowedWebSearchModes"),
            "approvals_reviewer" => Some("allowedApprovalsReviewers"),
            _ => None,
        };
        if let Some(values) = allowed.and_then(|key| requirements[key].as_array()) {
            setting.choices = values
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect();
            if values.is_empty() {
                setting.writable = false;
                setting.read_only_reason =
                    Some("Administrator policy permits no values for this setting".into());
            }
        }
        let fixed_requirement = match setting.key.as_str() {
            "chatgpt_base_url" => Some("chatgptBaseUrl"),
            "check_for_update_on_startup" => Some("checkForUpdateOnStartup"),
            "allow_login_shell" => Some("allowLoginShell"),
            "windows.sandbox_private_desktop" => Some("windowsSandboxPrivateDesktop"),
            "sqlite_home" => Some("sqliteHome"),
            "log_dir" => Some("logDir"),
            "model_catalog_json" => Some("modelCatalogJson"),
            _ => None,
        };
        let feedback_required = matches!(setting.key.as_str(), "feedback" | "feedback.enabled")
            && !requirements["feedback"]["enabled"].is_null();
        if feedback_required || fixed_requirement.is_some_and(|key| !requirements[key].is_null()) {
            setting.writable = false;
            setting.read_only_reason = Some("Value is fixed by administrator policy".into());
        }
        if let Some(feature) = setting.key.strip_prefix("features.") {
            if requirements["featureRequirements"].get(feature).is_some() {
                setting.writable = false;
                setting.read_only_reason =
                    Some("Feature value is required by administrator policy".into());
            }
        }
    }
}
fn describe(value: &Value, prefix: &str, writable: bool, out: &mut Vec<RuntimeSettingDescriptor>) {
    let Some(map) = value.as_object() else { return };
    for (key, value) in map {
        if sensitive(key) || key.starts_with('_') {
            continue;
        }
        let key = if prefix.is_empty() {
            key.clone()
        } else {
            format!("{prefix}.{key}")
        };
        if value.is_object() && !value.as_object().unwrap().is_empty() {
            describe(value, &key, writable, out);
        } else {
            out.push(RuntimeSettingDescriptor {label:key.clone(),key,value_json:value.to_string(),value_kind:match value {Value::Bool(_)=>RuntimeSettingValueKind::Boolean,Value::Number(_)=>RuntimeSettingValueKind::Number,Value::String(_)=>RuntimeSettingValueKind::String,_=>RuntimeSettingValueKind::Json},choices:vec![],scope:"user".into(),source:"Native runtime config/read".into(),writable,read_only_reason:(!writable).then(||"This host does not advertise a native settings writer; update the host helper".into())});
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn legacy_adapters_are_read_only_and_secrets_hidden() {
        let s = snapshot(
            "claude".into(),
            json!({"config":{"model":"opus","env":{"API_KEY":"private"}}}),
        )
        .unwrap();
        assert_eq!(s.settings.len(), 1);
        assert!(!s.settings[0].writable);
    }
    #[test]
    fn codex_retains_native_types() {
        let s = snapshot(
            "codex".into(),
            json!({"config":{"model":"gpt-5","features":{"fast_mode":true}}}),
        )
        .unwrap();
        assert_eq!(s.settings[0].value_kind, RuntimeSettingValueKind::Boolean);
        assert!(s.settings[0].writable);
    }
    #[test]
    fn codex_native_origins_and_requirements_constrain_editability() {
        let result=snapshot("codex".into(),json!({"config":{"approval_policy":"on-request","features":{"fast":true},"model":"gpt-5"},"origins":{"model":{"name":{"type":"user","file":"/tmp/profile.toml","profile":"work"},"version":"1"}},"_requirements":{"requirements":{"allowedApprovalPolicies":["on-request","never"],"featureRequirements":{"fast":true}}}})).unwrap();
        let approval = result
            .settings
            .iter()
            .find(|s| s.key == "approval_policy")
            .unwrap();
        assert_eq!(approval.choices, vec!["on-request", "never"]);
        assert!(approval.writable);
        assert!(
            !result
                .settings
                .iter()
                .find(|s| s.key == "features.fast")
                .unwrap()
                .writable
        );
        assert!(
            !result
                .settings
                .iter()
                .find(|s| s.key == "model")
                .unwrap()
                .writable
        );
    }
    #[test]
    fn codex_exact_nested_policies_disable_native_config_keys() {
        let result = snapshot("codex".into(), json!({
            "config":{"feedback":{"enabled":true},"windows":{"sandbox_private_desktop":true},"model":"custom"},
            "_requirements":{"requirements":{"feedback":{"enabled":false},"windowsSandboxPrivateDesktop":false}}
        })).unwrap();
        for key in ["feedback.enabled", "windows.sandbox_private_desktop"] {
            let descriptor = result
                .settings
                .iter()
                .find(|setting| setting.key == key)
                .unwrap();
            assert!(!descriptor.writable);
            assert_eq!(
                descriptor.read_only_reason.as_deref(),
                Some("Value is fixed by administrator policy")
            );
        }
        assert!(
            result
                .settings
                .iter()
                .find(|setting| setting.key == "model")
                .unwrap()
                .writable
        );
    }
    #[test]
    fn codex_structured_or_empty_policy_choices_are_not_falsely_editable() {
        let result = snapshot("codex".into(), json!({
            "config":{"approval_policy":{"granular":{"sandbox_approval":true}}, "sandbox_mode":"read-only"},
            "_requirements":{"requirements":{
                "allowedApprovalPolicies":[{"granular":{"sandbox_approval":true}}, "never"],
                "allowedSandboxModes":[]
            }}
        })).unwrap();
        assert_eq!(result.settings.len(), 2);
        assert!(result.settings.iter().all(|setting| !setting.writable));
    }
    #[test]
    fn nested_secret_payload_rejected() {
        assert!(validate_edit("providers", &json!({"x":{"apiKey":"private"}})).is_err());
    }
}
