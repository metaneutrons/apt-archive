use regex::Regex;
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    sync::OnceLock,
};

pub type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub domain: Domain,
    pub signing: Signing,
    pub publication: Publication,
    pub release: Release,
    pub projects: Vec<Project>,
    #[serde(skip)]
    pub path: PathBuf,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Domain {
    pub layout: String,
    pub host: String,
    pub base_url: String,
    pub origin: String,
    pub keyring_package: String,
    pub keyring_file: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Signing {
    pub primary_fingerprint: String,
    pub signing_subkey: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Publication {
    pub r2_bucket: String,
    pub r2_account_id: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Release {
    pub suite: String,
    pub codename: String,
    pub components: Vec<String>,
    pub architectures: Vec<String>,
    pub acquire_by_hash: bool,
    pub valid_until_days: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub name: String,
    pub source_repo: String,
    pub packages: Vec<String>,
    pub keep_versions: usize,
}

fn regex(pattern: &'static str, slot: &'static OnceLock<Regex>) -> &'static Regex {
    slot.get_or_init(|| Regex::new(pattern).expect("static regular expression"))
}

fn is_regular(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_file() && !metadata.file_type().is_symlink())
}

impl Manifest {
    pub fn load(path: &Path) -> Result<Self> {
        if !is_regular(path) {
            return Err(format!(
                "AR100 manifest must be a regular file: {}",
                path.display()
            ));
        }
        let text = fs::read_to_string(path)
            .map_err(|error| format!("AR100 cannot read {}: {error}", path.display()))?;
        let mut manifest: Self = toml::from_str(&text)
            .map_err(|error| format!("AR100 cannot parse {}: {error}", path.display()))?;
        manifest.path = path.to_path_buf();
        manifest.validate()?;
        Ok(manifest)
    }

    fn validate(&self) -> Result<()> {
        static HOST: OnceLock<Regex> = OnceLock::new();
        static PACKAGE: OnceLock<Regex> = OnceLock::new();
        static ABSOLUTE: OnceLock<Regex> = OnceLock::new();
        static SUITE: OnceLock<Regex> = OnceLock::new();
        static COMPONENT: OnceLock<Regex> = OnceLock::new();
        static ARCH: OnceLock<Regex> = OnceLock::new();
        static PROJECT: OnceLock<Regex> = OnceLock::new();
        static REPO: OnceLock<Regex> = OnceLock::new();
        static ACCOUNT: OnceLock<Regex> = OnceLock::new();
        static BUCKET: OnceLock<Regex> = OnceLock::new();
        static FINGERPRINT: OnceLock<Regex> = OnceLock::new();

        if self.domain.layout != "shared-root-v1" {
            return Err("AR100 domain layout must be shared-root-v1".into());
        }
        if !regex(r"^[a-z0-9]+(?:[.-][a-z0-9]+)*$", &HOST).is_match(&self.domain.host) {
            return Err("AR100 domain host must be a DNS hostname".into());
        }
        if self.domain.base_url != format!("https://{}", self.domain.host) {
            return Err("AR100 base_url must be the HTTPS domain root without a path".into());
        }
        if self.domain.origin.is_empty()
            || !self
                .domain
                .origin
                .bytes()
                .all(|byte| (0x20..=0x7e).contains(&byte))
        {
            return Err("AR100 origin must be one printable line".into());
        }
        if !regex(r"^[a-z0-9][a-z0-9+.-]+$", &PACKAGE).is_match(&self.domain.keyring_package) {
            return Err("AR100 keyring_package must be a Debian package name".into());
        }
        if !regex(r"^(?:/[A-Za-z0-9][A-Za-z0-9._+-]*)+$", &ABSOLUTE)
            .is_match(&self.domain.keyring_file)
        {
            return Err("AR100 keyring_file must be a plain absolute path".into());
        }
        if !regex(r"^[a-z0-9][a-z0-9._-]*$", &SUITE).is_match(&self.release.suite)
            || !regex(r"^[a-z0-9][a-z0-9._-]*$", &SUITE).is_match(&self.release.codename)
        {
            return Err("AR100 suite and codename must be safe path components".into());
        }
        if self.release.components.is_empty()
            || self
                .release
                .components
                .iter()
                .any(|value| !regex(r"^[a-z0-9][a-z0-9-]*$", &COMPONENT).is_match(value))
            || self
                .release
                .components
                .iter()
                .collect::<BTreeSet<_>>()
                .len()
                != self.release.components.len()
        {
            return Err("AR100 components must be non-empty, unique and safe".into());
        }
        if self.release.architectures.is_empty()
            || self.release.architectures.iter().any(|value| {
                value == "all" || !regex(r"^[a-z0-9][a-z0-9-]*$", &ARCH).is_match(value)
            })
            || self
                .release
                .architectures
                .iter()
                .collect::<BTreeSet<_>>()
                .len()
                != self.release.architectures.len()
        {
            return Err(
                "AR100 architectures must be non-empty, unique, safe and exclude all".into(),
            );
        }
        if !self.release.acquire_by_hash {
            return Err("AR100 acquire_by_hash must stay enabled".into());
        }
        if self.release.valid_until_days < 7 {
            return Err("AR100 valid_until_days must cover at least a week".into());
        }
        if !regex(r"^[a-z0-9][a-z0-9-]{1,63}$", &BUCKET).is_match(&self.publication.r2_bucket) {
            return Err("AR145 r2_bucket is malformed".into());
        }
        if !regex(r"^[0-9a-f]{32}$", &ACCOUNT).is_match(&self.publication.r2_account_id) {
            return Err("AR145 r2_account_id is malformed".into());
        }
        for value in [
            &self.signing.primary_fingerprint,
            &self.signing.signing_subkey,
        ] {
            if value != "TBD" && !regex(r"^[0-9A-Fa-f]{40}$", &FINGERPRINT).is_match(value) {
                return Err(format!("AR100 malformed signing fingerprint: {value}"));
            }
        }
        if self.projects.is_empty() {
            return Err("AR100 no project declared".into());
        }
        let mut names = BTreeSet::new();
        let mut owners = BTreeMap::new();
        for project in &self.projects {
            if !regex(r"^[a-z0-9][a-z0-9-]{1,63}$", &PROJECT).is_match(&project.name)
                || !names.insert(project.name.as_str())
            {
                return Err(format!(
                    "AR100 unsafe or duplicate project name: {}",
                    project.name
                ));
            }
            if !regex(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", &REPO).is_match(&project.source_repo) {
                return Err(format!(
                    "AR100 project {} has an unsafe source_repo",
                    project.name
                ));
            }
            if project.packages.is_empty() || project.keep_versions == 0 {
                return Err(format!(
                    "AR100 project {} has no package or keep_versions",
                    project.name
                ));
            }
            for package in &project.packages {
                if !regex(r"^[a-z0-9][a-z0-9+.-]+$", &PACKAGE).is_match(package)
                    || owners
                        .insert(package.as_str(), project.name.as_str())
                        .is_some()
                {
                    return Err(format!("AR100 unsafe or multiply owned package: {package}"));
                }
            }
        }
        Ok(())
    }

    pub fn project(&self, name: &str) -> Result<&Project> {
        self.projects
            .iter()
            .find(|project| project.name == name)
            .ok_or_else(|| format!("AR100 project {name:?} is not declared exactly once"))
    }

    pub fn owner(&self, package: &str) -> Result<&Project> {
        self.projects
            .iter()
            .find(|project| project.packages.iter().any(|owned| owned == package))
            .ok_or_else(|| format!("AR100 package {package:?} has no owner"))
    }

    pub fn all_packages(&self) -> BTreeSet<String> {
        self.projects
            .iter()
            .flat_map(|project| project.packages.iter().cloned())
            .collect()
    }

    pub fn component(&self, requested: Option<&str>) -> Result<String> {
        if let Some(component) = requested {
            if self
                .release
                .components
                .iter()
                .any(|known| known == component)
            {
                return Ok(component.to_string());
            }
            return Err(format!("AR100 component {component:?} is not declared"));
        }
        if self.release.components.len() == 1 {
            return Ok(self.release.components[0].clone());
        }
        Err("AR100 --component is required for a multi-component domain".into())
    }
}
