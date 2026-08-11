//! Cross-platform remote path handling.
//!
//! `std::path::Path` uses the *host* OS separator, which is always `/` on
//! iOS/Android. When manipulating paths on a remote Windows machine we need
//! string-based handling that knows the remote OS's conventions.

/// Normalize a user-facing cwd before it is sent to the app-server.
///
/// Upstream resolves relative cwd values against the app-server's configured
/// cwd. If mobile feeds a Windows fragment like `Users\npace` back into a
/// thread on an app-server rooted at `C:\Users\npace`, upstream turns it into
/// `C:\Users\npace\Users\npace`. Drop unexpanded fragments and collapse the
/// duplicated Windows home shape before the request leaves the mobile bridge.
pub fn normalize_thread_cwd(path: &str) -> Option<String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return None;
    }
    if looks_like_unexpanded_home_fragment(trimmed) {
        return None;
    }
    let parsed = RemotePath::parse(trimmed);
    let normalized = parsed.as_str();
    if parsed.is_windows() {
        Some(collapse_duplicated_windows_user_home(normalized))
    } else {
        Some(normalized.to_string())
    }
}

fn looks_like_unexpanded_home_fragment(path: &str) -> bool {
    if path.starts_with('/') {
        return false;
    }
    let normalized = path.replace('/', "\\");
    if normalized == "~" || normalized.starts_with("~\\") {
        return true;
    }
    let parts: Vec<&str> = normalized
        .split('\\')
        .filter(|part| !part.is_empty())
        .collect();
    parts.len() >= 2 && parts[0].eq_ignore_ascii_case("Users")
}

fn collapse_duplicated_windows_user_home(path: &str) -> String {
    let mut current = path.to_string();
    loop {
        let collapsed = collapse_one_duplicated_windows_user_home(&current);
        if collapsed == current {
            return current;
        }
        current = collapsed;
    }
}

fn collapse_one_duplicated_windows_user_home(path: &str) -> String {
    let parts: Vec<&str> = path.split('\\').filter(|part| !part.is_empty()).collect();
    if parts.len() < 5 {
        return path.to_string();
    }
    let drive = parts[0];
    if !(drive.len() == 2
        && drive.as_bytes()[0].is_ascii_alphabetic()
        && drive.as_bytes()[1] == b':')
    {
        return path.to_string();
    }
    if !parts[1].eq_ignore_ascii_case("Users")
        || !parts[3].eq_ignore_ascii_case("Users")
        || !parts[2].eq_ignore_ascii_case(parts[4])
    {
        return path.to_string();
    }
    let mut collapsed = vec![parts[0], parts[1], parts[2]];
    collapsed.extend_from_slice(&parts[5..]);
    collapsed.join("\\")
}

/// A remote filesystem path that knows whether it lives on a POSIX or
/// Windows host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemotePath {
    Posix(String),
    Windows(String),
}

impl RemotePath {
    /// Auto-detect the path kind from its format.
    ///
    /// A path is considered Windows if it starts with a drive letter followed
    /// by `:` (e.g. `C:\Users\...` or `D:`).  Everything else is POSIX.
    pub fn parse(path: &str) -> Self {
        let p = path.trim();
        let bytes = p.as_bytes();
        if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
            Self::Windows(normalize_windows_path(p))
        } else {
            Self::Posix(p.to_string())
        }
    }

    /// The raw path string.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Posix(s) | Self::Windows(s) => s,
        }
    }

    pub fn is_windows(&self) -> bool {
        matches!(self, Self::Windows(_))
    }

    pub fn separator(&self) -> char {
        if self.is_windows() { '\\' } else { '/' }
    }

    pub fn is_root(&self) -> bool {
        match self {
            Self::Posix(s) => s == "/",
            Self::Windows(s) => {
                // "C:\" or "C:"
                let b = s.as_bytes();
                (b.len() == 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\')
                    || (b.len() == 2 && b[0].is_ascii_alphabetic() && b[1] == b':')
            }
        }
    }

    /// Append a child name using the correct separator.
    pub fn join(&self, name: &str) -> Self {
        let sep = self.separator();
        let s = self.as_str();
        let next = if s.ends_with('/') || s.ends_with('\\') {
            format!("{s}{name}")
        } else {
            format!("{s}{sep}{name}")
        };
        match self {
            Self::Posix(_) => Self::Posix(next),
            Self::Windows(_) => Self::Windows(next),
        }
    }

    /// Navigate up one directory level. Root paths return themselves.
    pub fn parent(&self) -> Self {
        match self {
            Self::Posix(s) => {
                if s == "/" {
                    return self.clone();
                }
                match s.rfind('/') {
                    Some(0) => Self::Posix("/".to_string()),
                    Some(i) => Self::Posix(s[..i].to_string()),
                    None => Self::Posix("/".to_string()),
                }
            }
            Self::Windows(s) => {
                let parts: Vec<&str> = s.split('\\').collect();
                if parts.len() <= 1 {
                    return self.clone();
                }
                let parent_parts = &parts[..parts.len() - 1];
                let joined = parent_parts.join("\\");
                // Preserve trailing backslash for drive root (e.g. "C:\")
                if joined.ends_with(':') {
                    Self::Windows(format!("{joined}\\"))
                } else if joined.is_empty() {
                    self.clone()
                } else {
                    Self::Windows(joined)
                }
            }
        }
    }

    /// Split the path into breadcrumb segments.
    ///
    /// Each segment is `(label, full_path)`.
    pub fn segments(&self) -> Vec<(String, String)> {
        match self {
            Self::Posix(s) => {
                let normalized = s.trim();
                if normalized.is_empty() || normalized == "/" {
                    return vec![("/".to_string(), "/".to_string())];
                }
                let mut output = vec![("/".to_string(), "/".to_string())];
                let mut running = String::new();
                for component in normalized.split('/').filter(|c| !c.is_empty()) {
                    running = if running.is_empty() {
                        format!("/{component}")
                    } else {
                        format!("{running}/{component}")
                    };
                    output.push((component.to_string(), running.clone()));
                }
                output
            }
            Self::Windows(s) => {
                let normalized = s.trim();
                let parts: Vec<&str> = normalized.split('\\').filter(|c| !c.is_empty()).collect();
                if parts.is_empty() {
                    return vec![(normalized.to_string(), normalized.to_string())];
                }
                let mut output = Vec::new();
                let mut running = String::new();
                for (i, component) in parts.iter().enumerate() {
                    if i == 0 {
                        // Drive root: "C:\"
                        running = format!("{component}\\");
                        output.push((running.clone(), running.clone()));
                    } else {
                        running = if running.ends_with('\\') {
                            format!("{running}{component}")
                        } else {
                            format!("{running}\\{component}")
                        };
                        output.push((component.to_string(), running.clone()));
                    }
                }
                output
            }
        }
    }
}

fn normalize_windows_path(path: &str) -> String {
    let normalized = path.replace('/', "\\");
    let bytes = normalized.as_bytes();
    if bytes.len() == 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        format!("{normalized}\\")
    } else {
        normalized
    }
}

/// Parse the stdout of a directory listing command into sorted directory names.
pub fn parse_directory_listing(stdout: &str, is_windows: bool) -> Vec<String> {
    let mut dirs: Vec<String> = if is_windows {
        // `dir /b /ad` outputs one directory name per line
        stdout
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect()
    } else {
        // `ls -1ap` marks directories with trailing `/`
        stdout
            .lines()
            .map(|l| l.trim())
            .filter(|l| l.ends_with('/') && *l != "./" && *l != "../")
            .map(|l| l.trim_end_matches('/').to_string())
            .collect()
    };
    dirs.sort_by_key(|a| a.to_lowercase());
    dirs
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- parse / detection --

    #[test]
    fn parse_posix() {
        assert!(!RemotePath::parse("/home/user").is_windows());
        assert!(!RemotePath::parse("/").is_windows());
        assert!(!RemotePath::parse("relative/path").is_windows());
    }

    #[test]
    fn parse_windows() {
        assert!(RemotePath::parse(r"C:\Users\npace").is_windows());
        assert!(RemotePath::parse("D:").is_windows());
        assert!(RemotePath::parse(r"C:\").is_windows());
    }

    #[test]
    fn parse_windows_normalizes_forward_slashes() {
        assert_eq!(
            RemotePath::parse("D:/Projects/kitty").as_str(),
            r"D:\Projects\kitty"
        );
    }

    #[test]
    fn parse_windows_drive_only_normalizes_to_root() {
        assert_eq!(RemotePath::parse("D:").as_str(), r"D:\");
    }

    #[test]
    fn parse_trims_whitespace() {
        assert!(RemotePath::parse("  C:\\Users  ").is_windows());
        assert!(!RemotePath::parse("  /home  ").is_windows());
    }

    #[test]
    fn normalize_thread_cwd_collapses_duplicated_windows_home() {
        assert_eq!(
            normalize_thread_cwd(r"C:\Users\npace\Users\npace").as_deref(),
            Some(r"C:\Users\npace")
        );
    }

    #[test]
    fn normalize_thread_cwd_collapses_duplicated_windows_home_with_suffix() {
        assert_eq!(
            normalize_thread_cwd(r"C:\Users\npace\Users\npace\dev\litter").as_deref(),
            Some(r"C:\Users\npace\dev\litter")
        );
    }

    #[test]
    fn normalize_thread_cwd_collapses_repeated_duplicated_windows_home() {
        assert_eq!(
            normalize_thread_cwd(r"C:\Users\npace\Users\npace\Users\npace\dev").as_deref(),
            Some(r"C:\Users\npace\dev")
        );
    }

    #[test]
    fn normalize_thread_cwd_normalizes_windows_forward_slashes() {
        assert_eq!(
            normalize_thread_cwd("C:/Users/npace/dev/litter").as_deref(),
            Some(r"C:\Users\npace\dev\litter")
        );
    }

    #[test]
    fn normalize_thread_cwd_preserves_other_paths() {
        assert_eq!(
            normalize_thread_cwd(r"C:\Users\npace\Users\other").as_deref(),
            Some(r"C:\Users\npace\Users\other")
        );
        assert_eq!(
            normalize_thread_cwd("/home/npace/dev").as_deref(),
            Some("/home/npace/dev")
        );
        assert_eq!(
            normalize_thread_cwd("/Users/npace/dev").as_deref(),
            Some("/Users/npace/dev")
        );
        assert_eq!(normalize_thread_cwd("   "), None);
    }

    #[test]
    fn normalize_thread_cwd_rejects_unexpanded_windows_home_fragments() {
        assert_eq!(normalize_thread_cwd(r"Users\npace"), None);
        assert_eq!(normalize_thread_cwd(r"Users\npace\dev"), None);
        assert_eq!(normalize_thread_cwd(r"~\dev"), None);
        assert_eq!(normalize_thread_cwd("~/dev"), None);
    }

    // -- separator --

    #[test]
    fn separator() {
        assert_eq!(RemotePath::parse("/home").separator(), '/');
        assert_eq!(RemotePath::parse("C:\\").separator(), '\\');
    }

    // -- is_root --

    #[test]
    fn is_root_posix() {
        assert!(RemotePath::parse("/").is_root());
        assert!(!RemotePath::parse("/home").is_root());
    }

    #[test]
    fn is_root_windows() {
        assert!(RemotePath::parse(r"C:\").is_root());
        assert!(RemotePath::parse("C:").is_root());
        assert!(!RemotePath::parse(r"C:\Users").is_root());
    }

    // -- join --

    #[test]
    fn join_posix() {
        let p = RemotePath::parse("/home");
        assert_eq!(p.join("user").as_str(), "/home/user");
    }

    #[test]
    fn join_posix_trailing_slash() {
        let p = RemotePath::parse("/home/");
        assert_eq!(p.join("user").as_str(), "/home/user");
    }

    #[test]
    fn join_windows() {
        let p = RemotePath::parse(r"C:\Users");
        assert_eq!(p.join("npace").as_str(), r"C:\Users\npace");
    }

    #[test]
    fn join_windows_root() {
        let p = RemotePath::parse(r"C:\");
        assert_eq!(p.join("Users").as_str(), r"C:\Users");
    }

    // -- parent --

    #[test]
    fn parent_posix() {
        assert_eq!(RemotePath::parse("/home/user").parent().as_str(), "/home");
        assert_eq!(RemotePath::parse("/home").parent().as_str(), "/");
        assert_eq!(RemotePath::parse("/").parent().as_str(), "/");
    }

    #[test]
    fn parent_windows() {
        assert_eq!(
            RemotePath::parse(r"C:\Users\npace").parent().as_str(),
            r"C:\Users"
        );
        assert_eq!(RemotePath::parse(r"C:\Users").parent().as_str(), r"C:\");
        assert_eq!(RemotePath::parse(r"C:\").parent().as_str(), r"C:\");
    }

    #[test]
    fn parent_windows_forward_slashes() {
        assert_eq!(
            RemotePath::parse("D:/Projects/kitty").parent().as_str(),
            r"D:\Projects"
        );
    }

    // -- segments --

    #[test]
    fn segments_posix_root() {
        let segs = RemotePath::parse("/").segments();
        assert_eq!(segs, vec![("/".to_string(), "/".to_string())]);
    }

    #[test]
    fn segments_posix_deep() {
        let segs = RemotePath::parse("/home/user/docs").segments();
        assert_eq!(
            segs,
            vec![
                ("/".to_string(), "/".to_string()),
                ("home".to_string(), "/home".to_string()),
                ("user".to_string(), "/home/user".to_string()),
                ("docs".to_string(), "/home/user/docs".to_string()),
            ]
        );
    }

    #[test]
    fn segments_windows() {
        let segs = RemotePath::parse(r"C:\Users\npace").segments();
        assert_eq!(
            segs,
            vec![
                (r"C:\".to_string(), r"C:\".to_string()),
                ("Users".to_string(), r"C:\Users".to_string()),
                ("npace".to_string(), r"C:\Users\npace".to_string()),
            ]
        );
    }

    #[test]
    fn segments_windows_forward_slashes() {
        let segs = RemotePath::parse("D:/Projects/kitty").segments();
        assert_eq!(
            segs,
            vec![
                (r"D:\".to_string(), r"D:\".to_string()),
                ("Projects".to_string(), r"D:\Projects".to_string()),
                ("kitty".to_string(), r"D:\Projects\kitty".to_string()),
            ]
        );
    }

    #[test]
    fn segments_windows_root() {
        let segs = RemotePath::parse(r"C:\").segments();
        assert_eq!(segs, vec![(r"C:\".to_string(), r"C:\".to_string())]);
    }

    // -- parse_directory_listing --

    #[test]
    fn parse_listing_posix() {
        let stdout = "./\n../\nDocuments/\nDownloads/\n.hidden/\nfile.txt\n";
        let dirs = parse_directory_listing(stdout, false);
        assert_eq!(dirs, vec![".hidden", "Documents", "Downloads"]);
    }

    #[test]
    fn parse_listing_windows() {
        let stdout = "Documents\r\nDownloads\r\nDesktop\r\n";
        let dirs = parse_directory_listing(stdout, true);
        assert_eq!(dirs, vec!["Desktop", "Documents", "Downloads"]);
    }

    #[test]
    fn parse_listing_windows_no_crlf() {
        let stdout = "Documents\nDownloads\n";
        let dirs = parse_directory_listing(stdout, true);
        assert_eq!(dirs, vec!["Documents", "Downloads"]);
    }

    #[test]
    fn parse_listing_empty() {
        assert!(parse_directory_listing("", false).is_empty());
        assert!(parse_directory_listing("", true).is_empty());
    }

    #[test]
    fn parse_listing_posix_sorts_case_insensitive() {
        let stdout = "zebra/\nalpha/\nBeta/\n";
        let dirs = parse_directory_listing(stdout, false);
        assert_eq!(dirs, vec!["alpha", "Beta", "zebra"]);
    }
}
