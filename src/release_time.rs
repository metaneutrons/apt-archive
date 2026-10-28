use crate::manifest::{Manifest, Result};
use chrono::{DateTime, Utc};
use std::{
    fs,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

pub fn rfc2822(epoch: u64) -> Result<String> {
    let seconds = i64::try_from(epoch)
        .map_err(|_| format!("AR120 publication epoch is outside the supported range: {epoch}"))?;
    let stamp = DateTime::<Utc>::from_timestamp(seconds, 0).ok_or_else(|| {
        format!("AR120 publication epoch is outside the supported range: {epoch}")
    })?;
    Ok(stamp.to_rfc2822())
}

pub fn validate(
    manifest: &Manifest,
    release: &Path,
    publication_epoch: u64,
    now_epoch: Option<u64>,
    max_age_seconds: Option<u64>,
) -> Result<()> {
    if publication_epoch == 0 {
        return Err("AR120 publication epoch must be a positive integer".into());
    }
    let metadata = fs::symlink_metadata(release)
        .map_err(|error| format!("AR120 cannot inspect {}: {error}", release.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(format!(
            "AR120 Release must be a regular file: {}",
            release.display()
        ));
    }
    let text = fs::read_to_string(release)
        .map_err(|error| format!("AR120 cannot read {}: {error}", release.display()))?;
    let valid_until_epoch = publication_epoch
        .checked_add(manifest.release.valid_until_days.saturating_mul(86_400))
        .ok_or_else(|| "AR120 Valid-Until is outside the supported range".to_string())?;
    let expected_date = format!("Date: {}", rfc2822(publication_epoch)?);
    let expected_valid = format!("Valid-Until: {}", rfc2822(valid_until_epoch)?);
    one_header(&text, "Date", &expected_date)?;
    one_header(&text, "Valid-Until", &expected_valid)?;
    let now = match now_epoch {
        Some(value) => value,
        None => SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "AR120 current clock precedes the Unix epoch".to_string())?
            .as_secs(),
    };
    if now == 0 {
        return Err("AR120 current epoch must be a positive integer".into());
    }
    if publication_epoch > now {
        return Err(format!(
            "AR120 publication epoch {publication_epoch} is in the future relative to {now}"
        ));
    }
    if max_age_seconds.is_some_and(|limit| publication_epoch < now.saturating_sub(limit)) {
        return Err(format!(
            "AR120 publication epoch is {} seconds old",
            now - publication_epoch
        ));
    }
    if valid_until_epoch <= now {
        return Err(format!(
            "AR120 Release expired at {}",
            rfc2822(valid_until_epoch)?
        ));
    }
    Ok(())
}

fn one_header(text: &str, name: &str, expected: &str) -> Result<()> {
    let prefix = format!("{name}:");
    let matches = text
        .lines()
        .filter(|line| line.starts_with(&prefix))
        .collect::<Vec<_>>();
    if matches.len() != 1 {
        return Err(format!(
            "AR120 Release must carry exactly one {name} field, found {}",
            matches.len()
        ));
    }
    if matches[0] != expected {
        return Err(format!("AR120 Release {name} differs: {:?}", matches[0]));
    }
    Ok(())
}
