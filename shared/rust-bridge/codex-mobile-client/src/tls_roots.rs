use std::path::Path;

pub(crate) fn is_usable_pem_bundle(path: &Path) -> bool {
    const CERTIFICATE_HEADER: &[u8] = b"-----BEGIN CERTIFICATE-----";
    std::fs::read(path)
        .map(|contents| {
            contents
                .windows(CERTIFICATE_HEADER.len())
                .any(|window| window == CERTIFICATE_HEADER)
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::is_usable_pem_bundle;

    #[test]
    fn pem_bundle_validation_rejects_empty_or_truncated_files() {
        let temp_dir = tempfile::tempdir().expect("create temp dir");
        let pem_path = temp_dir.path().join("cacert.pem");

        std::fs::write(&pem_path, []).expect("write empty bundle");
        assert!(!is_usable_pem_bundle(&pem_path));

        std::fs::write(&pem_path, b"-----BEGIN CERT").expect("write truncated bundle");
        assert!(!is_usable_pem_bundle(&pem_path));

        std::fs::write(
            &pem_path,
            b"-----BEGIN CERTIFICATE-----\ncertificate-data\n-----END CERTIFICATE-----\n",
        )
        .expect("write usable bundle");
        assert!(is_usable_pem_bundle(&pem_path));
    }
}
