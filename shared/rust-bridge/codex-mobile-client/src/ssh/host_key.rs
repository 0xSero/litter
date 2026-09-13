//! Shared decoding of SSH trust failures crossing the UniFFI error boundary.

/// A rejected SSH identity. The caller retains the connection's host and port;
/// neither is recovered from display text or used as part of the stored pin.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SshHostKeyChallenge {
    pub fingerprint: String,
    pub is_changed: bool,
}

/// Decode saved-server and terminal errors, including UniFFI exception wrappers.
/// Terminal errors may include a hostname (including IPv6) before the fingerprint.
#[uniffi::export]
pub fn decode_ssh_host_key_challenge(message: String) -> Option<SshHostKeyChallenge> {
    let (tail, is_changed) = if let Some((_, tail)) = message.split_once("host-key-changed:") {
        (tail, true)
    } else if let Some((_, tail)) = message.split_once("unknown-host:") {
        (tail, false)
    } else {
        return None;
    };
    let fingerprint = if let Some(value) = tail.strip_prefix("SHA256:") {
        value
    } else if is_changed {
        tail.rsplit_once(":SHA256:")?.1
    } else {
        return None;
    };
    let digest: String = fingerprint
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '/'))
        .collect();
    // russh prints an unpadded base64 SHA-256 digest (32 bytes / 43 chars).
    // Reject missing/truncated fingerprints rather than offering an invalid pin.
    if digest.len() != 43 {
        return None;
    }
    Some(SshHostKeyChallenge {
        fingerprint: format!("SHA256:{digest}"),
        is_changed,
    })
}

pub(crate) fn ssh_host_key_is_trusted(
    pin: Option<&str>,
    fingerprint: &str,
    accept_unknown: bool,
) -> bool {
    pin.map_or(accept_unknown, |expected| expected == fingerprint)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_server_and_uniffi_errors_decode_without_wrapper_punctuation() {
        let fingerprint = format!("SHA256:{}", "a".repeat(43));
        for marker in ["unknown-host", "host-key-changed"] {
            for message in [
                format!("{marker}:{fingerprint}"),
                format!("Backend(detail: \"{marker}:{fingerprint}\")"),
                format!("Ssh(message='{marker}:{fingerprint}')"),
            ] {
                let challenge = decode_ssh_host_key_challenge(message).unwrap();
                assert_eq!(challenge.fingerprint, fingerprint);
                assert_eq!(challenge.is_changed, marker == "host-key-changed");
            }
        }
    }

    #[test]
    fn unrelated_and_incomplete_errors_do_not_offer_trust() {
        for message in [
            "connect-failed:timeout",
            "host-key-changed:example.com",
            "unknown-host:SHA256:short",
        ] {
            assert_eq!(decode_ssh_host_key_challenge(message.into()), None);
        }
    }
}
