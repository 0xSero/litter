use crate::types::{AppPetFrameContract, AppPetPackage, AppPetSummary};
use serde::Deserialize;
use std::path::PathBuf;

pub const PET_COLUMNS: u32 = 8;
pub const PET_ROWS: u32 = 9;
pub const PET_FRAME_WIDTH: u32 = 192;
pub const PET_FRAME_HEIGHT: u32 = 208;
pub const PET_ATLAS_WIDTH: u32 = PET_COLUMNS * PET_FRAME_WIDTH;
pub const PET_ATLAS_HEIGHT: u32 = PET_ROWS * PET_FRAME_HEIGHT;

pub const PET_STATE_ROWS: [&str; PET_ROWS as usize] = [
    "idle",
    "running-right",
    "running-left",
    "waving",
    "jumping",
    "failed",
    "waiting",
    "running",
    "review",
];

#[derive(Debug, Clone)]
pub struct ParsedPetManifest {
    pub id: String,
    pub display_name: String,
    pub description: Option<String>,
    pub spritesheet_file_name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PetManifestWire {
    id: Option<String>,
    name: Option<String>,
    #[serde(alias = "display_name")]
    display_name: Option<String>,
    description: Option<String>,
    #[serde(alias = "spritesheet_path")]
    spritesheet_path: Option<String>,
    spritesheet: Option<String>,
}

pub fn frame_contract() -> AppPetFrameContract {
    AppPetFrameContract {
        columns: PET_COLUMNS,
        rows: PET_ROWS,
        frame_width: PET_FRAME_WIDTH,
        frame_height: PET_FRAME_HEIGHT,
        atlas_width: PET_ATLAS_WIDTH,
        atlas_height: PET_ATLAS_HEIGHT,
        state_rows: PET_STATE_ROWS
            .iter()
            .map(|row| (*row).to_string())
            .collect(),
    }
}

pub fn parse_pet_manifest(
    pet_dir_path: &str,
    manifest_json: &str,
) -> Result<ParsedPetManifest, String> {
    let wire: PetManifestWire = serde_json::from_str(manifest_json)
        .map_err(|error| format!("invalid pet.json: {error}"))?;
    let fallback_id = pet_dir_path
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("pet")
        .trim()
        .to_string();
    let id = wire
        .id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback_id.as_str())
        .to_string();
    let display_name = wire
        .display_name
        .or(wire.name)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| titleize_pet_id(&id));
    let spritesheet_path = wire
        .spritesheet_path
        .or(wire.spritesheet)
        .unwrap_or_else(|| "spritesheet.webp".to_string());
    let spritesheet_file_name = validate_spritesheet_file_name(&spritesheet_path)?;

    Ok(ParsedPetManifest {
        id,
        display_name,
        description: wire
            .description
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty()),
        spritesheet_file_name: Some(spritesheet_file_name),
    })
}

pub fn summary_from_manifest(
    source_path: String,
    manifest_json: &str,
    spritesheet_exists: bool,
) -> AppPetSummary {
    match parse_pet_manifest(&source_path, manifest_json) {
        Ok(manifest) => {
            let validation_error = if spritesheet_exists {
                None
            } else {
                Some("spritesheet.webp is missing".to_string())
            };
            AppPetSummary {
                id: manifest.id,
                display_name: manifest.display_name,
                description: manifest.description,
                source_path,
                spritesheet_path: manifest.spritesheet_file_name,
                has_valid_spritesheet: validation_error.is_none(),
                validation_error,
            }
        }
        Err(error) => {
            let fallback_id = source_path
                .trim_end_matches(['/', '\\'])
                .rsplit(['/', '\\'])
                .next()
                .unwrap_or("pet")
                .to_string();
            AppPetSummary {
                id: fallback_id.clone(),
                display_name: titleize_pet_id(&fallback_id),
                description: None,
                source_path,
                spritesheet_path: None,
                has_valid_spritesheet: false,
                validation_error: Some(error),
            }
        }
    }
}

pub fn package_from_parts(
    source_path: String,
    manifest_json: &str,
    spritesheet_bytes: Vec<u8>,
) -> Result<AppPetPackage, String> {
    let manifest = parse_pet_manifest(&source_path, manifest_json)?;
    let dimensions = webp_dimensions(&spritesheet_bytes)?;
    if dimensions != (PET_ATLAS_WIDTH, PET_ATLAS_HEIGHT) {
        return Err(format!(
            "spritesheet must be {PET_ATLAS_WIDTH}x{PET_ATLAS_HEIGHT}, got {}x{}",
            dimensions.0, dimensions.1
        ));
    }
    let summary = AppPetSummary {
        id: manifest.id,
        display_name: manifest.display_name,
        description: manifest.description,
        source_path,
        spritesheet_path: manifest.spritesheet_file_name,
        has_valid_spritesheet: true,
        validation_error: None,
    };
    Ok(AppPetPackage {
        summary,
        frame_contract: frame_contract(),
        spritesheet_bytes,
    })
}

pub fn local_spritesheet_path(pet_dir_path: &str, file_name: &str) -> Result<String, String> {
    let file_name = validate_spritesheet_file_name(file_name)?;
    if is_windows_path(pet_dir_path) {
        let separator = if pet_dir_path.ends_with(['\\', '/']) {
            ""
        } else {
            "\\"
        };
        return Ok(format!("{pet_dir_path}{separator}{file_name}"));
    }

    let mut path = PathBuf::from(pet_dir_path);
    path.push(file_name);
    path.to_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| "spritesheet path is not valid UTF-8".to_string())
}

fn validate_spritesheet_file_name(value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("spritesheet path is empty".to_string());
    }
    if trimmed.contains('/') || trimmed.contains('\\') || trimmed == "." || trimmed == ".." {
        return Err("spritesheet path must be a file in the pet folder".to_string());
    }
    if !trimmed.to_ascii_lowercase().ends_with(".webp") {
        return Err("spritesheet must be a WebP file".to_string());
    }
    Ok(trimmed.to_string())
}

fn titleize_pet_id(id: &str) -> String {
    id.split(['-', '_', ' '])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn is_windows_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 3 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic()
}

fn webp_dimensions(bytes: &[u8]) -> Result<(u32, u32), String> {
    if bytes.len() < 16 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WEBP" {
        return Err("spritesheet is not a WebP image".to_string());
    }

    let mut offset = 12usize;
    while offset + 8 <= bytes.len() {
        let chunk = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(
            bytes[offset + 4..offset + 8]
                .try_into()
                .map_err(|_| "invalid WebP chunk size".to_string())?,
        ) as usize;
        let data_start = offset + 8;
        let data_end = data_start
            .checked_add(size)
            .ok_or_else(|| "invalid WebP chunk size".to_string())?;
        if data_end > bytes.len() {
            return Err("truncated WebP chunk".to_string());
        }
        match chunk {
            b"VP8X" if size >= 10 => {
                let width = 1
                    + u32::from(bytes[data_start + 4])
                    + (u32::from(bytes[data_start + 5]) << 8)
                    + (u32::from(bytes[data_start + 6]) << 16);
                let height = 1
                    + u32::from(bytes[data_start + 7])
                    + (u32::from(bytes[data_start + 8]) << 8)
                    + (u32::from(bytes[data_start + 9]) << 16);
                return Ok((width, height));
            }
            b"VP8L" if size >= 5 => {
                if bytes[data_start] != 0x2f {
                    return Err("invalid WebP lossless header".to_string());
                }
                let bits = u32::from_le_bytes(
                    bytes[data_start + 1..data_start + 5]
                        .try_into()
                        .map_err(|_| "invalid WebP lossless header".to_string())?,
                );
                let width = (bits & 0x3fff) + 1;
                let height = ((bits >> 14) & 0x3fff) + 1;
                return Ok((width, height));
            }
            b"VP8 " if size >= 10 => {
                if bytes[data_start + 3..data_start + 6] != [0x9d, 0x01, 0x2a] {
                    return Err("invalid WebP lossy header".to_string());
                }
                let width = u32::from(
                    u16::from_le_bytes(
                        bytes[data_start + 6..data_start + 8]
                            .try_into()
                            .map_err(|_| "invalid WebP lossy width".to_string())?,
                    ) & 0x3fff,
                );
                let height = u32::from(
                    u16::from_le_bytes(
                        bytes[data_start + 8..data_start + 10]
                            .try_into()
                            .map_err(|_| "invalid WebP lossy height".to_string())?,
                    ) & 0x3fff,
                );
                return Ok((width, height));
            }
            _ => {}
        }
        offset = data_end + (size % 2);
    }

    Err("WebP dimensions were not found".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn vp8x_webp(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&18u32.to_le_bytes());
        bytes.extend_from_slice(b"WEBP");
        bytes.extend_from_slice(b"VP8X");
        bytes.extend_from_slice(&10u32.to_le_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 0]);
        let w = width - 1;
        let h = height - 1;
        bytes.extend_from_slice(&[
            (w & 0xff) as u8,
            ((w >> 8) & 0xff) as u8,
            ((w >> 16) & 0xff) as u8,
            (h & 0xff) as u8,
            ((h >> 8) & 0xff) as u8,
            ((h >> 16) & 0xff) as u8,
        ]);
        bytes
    }

    #[test]
    fn parses_hatch_pet_manifest() {
        let parsed = parse_pet_manifest(
            "/Users/me/.codex/pets/dewey",
            r#"{"id":"dewey","displayName":"Dewey","description":"Duck","spritesheetPath":"spritesheet.webp"}"#,
        )
        .unwrap();
        assert_eq!(parsed.id, "dewey");
        assert_eq!(parsed.display_name, "Dewey");
        assert_eq!(
            parsed.spritesheet_file_name.as_deref(),
            Some("spritesheet.webp")
        );
    }

    #[test]
    fn rejects_path_escape() {
        let error = parse_pet_manifest(
            "/pets/bad",
            r#"{"id":"bad","spritesheetPath":"../spritesheet.webp"}"#,
        )
        .unwrap_err();
        assert!(error.contains("pet folder"));
    }

    #[test]
    fn validates_expected_atlas_dimensions() {
        let package = package_from_parts(
            "/pets/codex".to_string(),
            r#"{"id":"codex","spritesheetPath":"spritesheet.webp"}"#,
            vp8x_webp(PET_ATLAS_WIDTH, PET_ATLAS_HEIGHT),
        )
        .unwrap();
        assert_eq!(package.frame_contract.state_rows[8], "review");
    }

    #[test]
    fn rejects_bad_atlas_dimensions() {
        let error = package_from_parts(
            "/pets/codex".to_string(),
            r#"{"id":"codex","spritesheetPath":"spritesheet.webp"}"#,
            vp8x_webp(100, 100),
        )
        .unwrap_err();
        assert!(error.contains("1536x1872"));
    }

    #[test]
    fn bad_manifest_becomes_invalid_summary() {
        let summary = summary_from_manifest("/pets/bad".to_string(), "{", false);
        assert!(!summary.has_valid_spritesheet);
        assert!(
            summary
                .validation_error
                .unwrap()
                .contains("invalid pet.json")
        );
    }

    #[test]
    fn joins_local_spritesheet_path() {
        assert_eq!(
            local_spritesheet_path("/tmp/pets/codex", "spritesheet.webp").unwrap(),
            Path::new("/tmp/pets/codex")
                .join("spritesheet.webp")
                .to_str()
                .unwrap()
        );
    }
}
