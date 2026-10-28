use crate::manifest::{Manifest, Result};
use regex::Regex;
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
    sync::OnceLock,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Handoff {
    schema: String,
    status: String,
    version: String,
    release_tag: String,
    qualification: Qualification,
    assets: Vec<Identity>,
    direct: Direct,
    rustup: Rustup,
    apt: Apt,
    homebrew: Homebrew,
    claim: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Qualification {
    run_id: u64,
    run_attempt: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Direct {
    archives: Vec<Identity>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rustup {
    manifest: String,
    checksum: String,
    component_count: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Apt {
    repository: String,
    packages: Vec<Identity>,
    inputs: Vec<Identity>,
    rebuild_sdk: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Homebrew {
    repository: String,
    formula: Identity,
    input: Identity,
    archive: Identity,
    rebuild_sdk: bool,
}

#[derive(Deserialize)]
pub struct GithubAsset {
    pub name: String,
    pub size: u64,
    pub digest: Option<String>,
}

#[derive(Deserialize)]
pub struct GithubRelease {
    #[serde(rename = "tagName")]
    pub tag_name: String,
    pub assets: Vec<GithubAsset>,
}

pub type SelectedPackage = (String, String, String, String, String);

pub fn select(
    manifest: &Manifest,
    project: &str,
    handoff_path: &Path,
    version: &str,
    release: &GithubRelease,
) -> Result<Vec<SelectedPackage>> {
    let selected = manifest.project(project)?;
    if project != "ami-rust" || selected.source_repo != "metaneutrons/ami-rust" {
        return Err("AR175 signed channel handoff is reserved for the ami-rust project".into());
    }
    let metadata = fs::symlink_metadata(handoff_path)
        .map_err(|error| format!("AR175 cannot inspect channel handoff: {error}"))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 16 * 1024 * 1024
    {
        return Err("AR175 channel handoff must be a bounded regular file".into());
    }
    let bytes = fs::read(handoff_path)
        .map_err(|error| format!("AR175 cannot read channel handoff: {error}"))?;
    let handoff: Handoff = serde_json::from_slice(&bytes)
        .map_err(|error| format!("AR175 invalid channel handoff: {error}"))?;
    if handoff.schema != "ami-rust-rp3-channel-handoff-v1"
        || handoff.status != "EXACT_RELEASE_ASSET_IDENTITIES_FOR_PACKAGE_CHANNELS"
        || handoff.version != version
        || handoff.release_tag != format!("v{version}")
        || release.tag_name != handoff.release_tag
        || handoff.apt.repository != "metaneutrons/apt-archive"
        || handoff.apt.rebuild_sdk
        || handoff.homebrew.rebuild_sdk
        || handoff.qualification.run_id == 0
        || handoff.qualification.run_attempt == 0
        || handoff.rustup.component_count == 0
        || handoff.direct.archives.is_empty()
        || handoff.apt.inputs.is_empty()
        || handoff.homebrew.repository != "metaneutrons/homebrew-tap"
        || handoff.homebrew.formula.name.is_empty()
        || handoff.homebrew.input.name.is_empty()
        || handoff.homebrew.archive.name.is_empty()
        || handoff.rustup.manifest.is_empty()
        || handoff.rustup.checksum.is_empty()
        || handoff.claim.is_empty()
    {
        return Err("AR175 channel handoff contract is incomplete or inconsistent".into());
    }
    let identities = validate_identities(&handoff.assets)?;
    for identity in handoff
        .direct
        .archives
        .iter()
        .chain(handoff.apt.packages.iter())
        .chain(handoff.apt.inputs.iter())
    {
        if identities.get(&identity.name) != Some(identity) {
            return Err(format!(
                "AR175 channel identity {} is absent from the signed asset inventory",
                identity.name
            ));
        }
    }
    let public = release
        .assets
        .iter()
        .map(|asset| (asset.name.as_str(), asset))
        .collect::<BTreeMap<_, _>>();
    static SHA256: OnceLock<Regex> = OnceLock::new();
    let sha = SHA256.get_or_init(|| Regex::new(r"^[0-9a-f]{64}$").unwrap());
    for identity in &handoff.apt.packages {
        if !sha.is_match(&identity.sha256) || identity.bytes == 0 {
            return Err("AR175 APT package identity is malformed".into());
        }
        let asset = public
            .get(identity.name.as_str())
            .ok_or_else(|| format!("AR175 public release lacks {}", identity.name))?;
        if asset.size != identity.bytes
            || asset.digest.as_deref() != Some(&format!("sha256:{}", identity.sha256))
        {
            return Err(format!(
                "AR175 public release identity differs for {}",
                identity.name
            ));
        }
    }
    let expected = manifest
        .release
        .architectures
        .iter()
        .map(|architecture| format!("ami-rust_{version}_{architecture}.deb"))
        .collect::<BTreeSet<_>>();
    let actual = handoff
        .apt
        .packages
        .iter()
        .map(|identity| identity.name.clone())
        .collect::<BTreeSet<_>>();
    if actual != expected {
        return Err(
            "AR175 signed handoff does not contain the complete APT architecture set".into(),
        );
    }
    Ok(handoff
        .apt
        .packages
        .into_iter()
        .map(|identity| {
            let architecture = identity
                .name
                .strip_suffix(".deb")
                .and_then(|name| name.rsplit_once('_'))
                .map(|(_, arch)| arch)
                .unwrap_or_default()
                .to_string();
            (
                handoff.release_tag.clone(),
                identity.name,
                "ami-rust".to_string(),
                version.to_string(),
                architecture,
            )
        })
        .collect())
}

fn validate_identities(identities: &[Identity]) -> Result<BTreeMap<String, Identity>> {
    static NAME: OnceLock<Regex> = OnceLock::new();
    static SHA256: OnceLock<Regex> = OnceLock::new();
    let name = NAME.get_or_init(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$").unwrap());
    let sha = SHA256.get_or_init(|| Regex::new(r"^[0-9a-f]{64}$").unwrap());
    let mut result = BTreeMap::new();
    for identity in identities {
        if identity.bytes == 0
            || !name.is_match(&identity.name)
            || !sha.is_match(&identity.sha256)
            || result
                .insert(identity.name.clone(), identity.clone())
                .is_some()
        {
            return Err("AR175 signed asset inventory contains an invalid identity".into());
        }
    }
    Ok(result)
}
