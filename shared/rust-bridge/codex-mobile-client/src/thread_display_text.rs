//! Cleanup for thread titles and previews that come from agent transcripts.
//!
//! Claude Code writes harness bookkeeping into the user turn of its session
//! journal: `<local-command-caveat>` notes, `<command-name>` /
//! `<command-message>` / `<command-args>` wrappers for slash commands,
//! `<local-command-stdout>` output, and `<system-reminder>` blocks. Bridges
//! that derive a thread preview from the first user message pass that markup
//! through verbatim, so session lists and headers showed
//! `<local-command-caveat>The command below was run…` instead of a title.
//!
//! This is the single place that turns such text into something displayable.
//! Both platforms read the sanitized `ThreadInfo`, so neither Swift nor
//! Kotlin parses these tags.

/// Wrapper tags whose whole block is harness bookkeeping and never a title.
const DROPPED_BLOCK_TAGS: &[&str] = &[
    "local-command-caveat",
    "local-command-stdout",
    "local-command-stderr",
    "system-reminder",
    "command-message",
    "user-prompt-submit-hook",
    "bash-stdout",
    "bash-stderr",
];

/// Wrapper tags whose inner text is meaningful (for example the slash command
/// that was run), so the tags are removed and the content kept.
const UNWRAPPED_TAGS: &[&str] = &["command-name", "command-args", "bash-input"];

/// Returns `text` with Claude Code wrapper markup removed and whitespace
/// collapsed, or `None` when nothing displayable is left.
pub fn sanitize_thread_display_text(text: &str) -> Option<String> {
    let has_wrapper = DROPPED_BLOCK_TAGS
        .iter()
        .chain(UNWRAPPED_TAGS)
        .any(|tag| find_open_tag(text, &format!("<{tag}")).is_some());
    if !has_wrapper {
        return (!text.trim().is_empty()).then(|| text.to_string());
    }
    let mut out = text.to_string();
    for tag in DROPPED_BLOCK_TAGS {
        out = remove_tag_blocks(&out, tag);
    }
    for tag in UNWRAPPED_TAGS {
        out = unwrap_tag(&out, tag);
    }
    let collapsed = collapse_whitespace(&out);
    (!collapsed.is_empty()).then_some(collapsed)
}

/// Sanitizes an optional title/preview, mapping markup-only text to `None`.
pub fn sanitize_optional_thread_display_text(text: Option<String>) -> Option<String> {
    let text = text?;
    sanitize_thread_display_text(&text)
}

/// Removes every `<tag …>…</tag>` block. An unterminated opening tag drops
/// the rest of the text, which matches how previews are truncated mid-block.
fn remove_tag_blocks(text: &str, tag: &str) -> String {
    let open_prefix = format!("<{tag}");
    let close = format!("</{tag}>");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = find_open_tag(rest, &open_prefix) {
        out.push_str(&rest[..start]);
        let after_open = &rest[start..];
        match after_open.find(&close) {
            Some(end) => {
                rest = &after_open[end + close.len()..];
                out.push(' ');
            }
            None => {
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

/// Removes `<tag …>` and `</tag>` markers but keeps the enclosed text.
fn unwrap_tag(text: &str, tag: &str) -> String {
    let open_prefix = format!("<{tag}");
    let close = format!("</{tag}>");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = find_open_tag(rest, &open_prefix) {
        out.push_str(&rest[..start]);
        let after = &rest[start..];
        match after.find('>') {
            Some(gt) => {
                out.push(' ');
                rest = &after[gt + 1..];
            }
            None => {
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out.replace(&close, " ")
}

/// Finds `<tag` only when it is followed by `>` or whitespace, so `<tag`
/// does not match a longer tag name such as `<tag-extra>`.
fn find_open_tag(text: &str, open_prefix: &str) -> Option<usize> {
    let mut offset = 0;
    while let Some(found) = text[offset..].find(open_prefix) {
        let start = offset + found;
        let next = text[start + open_prefix.len()..].chars().next();
        match next {
            Some('>') | Some(' ') | Some('\n') | Some('\t') | Some('/') => return Some(start),
            None => return Some(start),
            _ => offset = start + open_prefix.len(),
        }
    }
    None
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caveat_only_preview_has_nothing_to_show() {
        let text = "<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request, and its output goes straight to the user. It's recorded here as context for later messages.</local-command-caveat>";
        assert_eq!(sanitize_thread_display_text(text), None);
    }

    #[test]
    fn slash_command_wrapper_keeps_the_command() {
        let text = "<command-name>/claim-credit</command-name>\n            <command-message>claim-credit</command-message>\n            <command-args></command-args>";
        assert_eq!(
            sanitize_thread_display_text(text).as_deref(),
            Some("/claim-credit")
        );
    }

    #[test]
    fn slash_command_args_are_kept() {
        let text = "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>PR 402</command-args>";
        assert_eq!(
            sanitize_thread_display_text(text).as_deref(),
            Some("/review PR 402")
        );
    }

    #[test]
    fn caveat_followed_by_real_text_keeps_the_text() {
        let text = "<local-command-caveat>Caveat.</local-command-caveat>\n\nFix the launch crash";
        assert_eq!(
            sanitize_thread_display_text(text).as_deref(),
            Some("Fix the launch crash")
        );
    }

    #[test]
    fn system_reminder_and_stdout_blocks_are_dropped() {
        let text = "<system-reminder>\nremember things\n</system-reminder>Deploy it <local-command-stdout>ok</local-command-stdout>";
        assert_eq!(
            sanitize_thread_display_text(text).as_deref(),
            Some("Deploy it")
        );
    }

    #[test]
    fn truncated_block_drops_the_tail() {
        let text = "<local-command-caveat>The command below was run directly in Claude Cod";
        assert_eq!(sanitize_thread_display_text(text), None);
    }

    #[test]
    fn plain_text_and_ordinary_angle_brackets_are_untouched() {
        assert_eq!(
            sanitize_thread_display_text("Compare Vec<u8>\nand <div> tags").as_deref(),
            Some("Compare Vec<u8>\nand <div> tags")
        );
        assert_eq!(
            sanitize_thread_display_text("<command-name-extra>x</command-name-extra>").as_deref(),
            Some("<command-name-extra>x</command-name-extra>")
        );
    }

    #[test]
    fn optional_helper_maps_empty_to_none() {
        assert_eq!(sanitize_optional_thread_display_text(None), None);
        assert_eq!(sanitize_optional_thread_display_text(Some("   ".into())), None);
        assert_eq!(
            sanitize_optional_thread_display_text(Some("Title".into())).as_deref(),
            Some("Title")
        );
    }
}
