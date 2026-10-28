use crate::{
    archive::{ArchiveState, PublicationPlan},
    deb::{self, Binary},
    manifest::{Manifest, Result},
    process, release_time,
};
use flate2::read::GzDecoder;
use regex::Regex;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256, Sha512};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::Read,
    path::{Component, Path, PathBuf},
    process::Command,
    sync::OnceLock,
    time::{SystemTime, UNIX_EPOCH},
};
use tempfile::TempDir;
use walkdir::WalkDir;

const MIB: u64 = 1024 * 1024;
const MAX_STATE: u64 = 16 * MIB;
const MAX_PACKAGES: usize = 4096;
const MAX_TOTAL: u64 = 16 * 1024 * MIB;
type ReleaseHashes = BTreeMap<String, BTreeMap<String, (String, u64)>>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Baseline {
    pub schema_version: u32,
    pub base_url: String,
    pub suite: String,
    pub inrelease_sha256: Option<String>,
    pub publication_epoch: u64,
    pub inrelease_etag: Option<String>,
}

trait Store {
    fn get(
        &mut self,
        key: &str,
        target: &Path,
        limit: u64,
        optional: bool,
    ) -> Result<Option<String>>;
    fn empty(&self) -> Result<bool>;
}

struct AwsStore {
    bucket: String,
    endpoint: String,
}

impl AwsStore {
    fn new(manifest: &Manifest) -> Self {
        Self {
            bucket: manifest.publication.r2_bucket.clone(),
            endpoint: format!(
                "https://{}.r2.cloudflarestorage.com",
                manifest.publication.r2_account_id
            ),
        }
    }

    fn base(&self) -> Command {
        let mut command = Command::new("aws");
        command.args(["s3api", "--endpoint-url", &self.endpoint]);
        command
    }
}

impl Store for AwsStore {
    fn get(
        &mut self,
        key: &str,
        target: &Path,
        limit: u64,
        optional: bool,
    ) -> Result<Option<String>> {
        safe_key(key)?;
        if limit > 512 * MIB {
            return Err("AR190 invalid object read limit".into());
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(io_error)?;
        }
        let output = self
            .base()
            .args([
                "get-object",
                "--bucket",
                &self.bucket,
                "--key",
                key,
                "--range",
                &format!("bytes=0-{limit}"),
            ])
            .arg(target)
            .output()
            .map_err(|error| format!("AR190 cannot execute aws: {error}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if optional && (stderr.contains("(NoSuchKey)") || stderr.contains("(404)")) {
                if target.exists() {
                    return Err(format!("AR190 failed read left a partial object: {key}"));
                }
                return Ok(None);
            }
            return Err(format!("AR190 cannot read object {key}: {}", stderr.trim()));
        }
        let metadata = regular_bounded(target, limit, "downloaded object")?;
        let response: serde_json::Value = serde_json::from_slice(&output.stdout)
            .map_err(|error| format!("AR190 cannot parse aws response: {error}"))?;
        let etag = response
            .get("ETag")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| "AR190 object has no ETag".to_string())?;
        static ETAG: OnceLock<Regex> = OnceLock::new();
        if !ETAG
            .get_or_init(|| Regex::new(r#"^"[A-Za-z0-9-]+"$"#).unwrap())
            .is_match(etag)
        {
            return Err("AR190 object ETag is malformed".into());
        }
        if metadata.len() > limit {
            return Err(format!("AR190 object {key} exceeds its bound"));
        }
        Ok(Some(etag.to_string()))
    }

    fn empty(&self) -> Result<bool> {
        let output = self
            .base()
            .args([
                "list-objects-v2",
                "--bucket",
                &self.bucket,
                "--max-keys",
                "1",
                "--no-paginate",
            ])
            .output()
            .map_err(|error| format!("AR190 cannot execute aws: {error}"))?;
        if !output.status.success() {
            return Err("AR190 cannot list archive bucket".into());
        }
        let value: serde_json::Value = serde_json::from_slice(&output.stdout)
            .map_err(|error| format!("AR190 cannot parse bucket listing: {error}"))?;
        Ok(
            value.get("KeyCount").and_then(serde_json::Value::as_u64) == Some(0)
                && value
                    .get("IsTruncated")
                    .and_then(serde_json::Value::as_bool)
                    == Some(false)
                && value.get("Contents").is_none(),
        )
    }
}

struct DirectoryStore {
    root: PathBuf,
}

impl DirectoryStore {
    fn new(root: &Path) -> Result<Self> {
        let metadata = fs::symlink_metadata(root)
            .map_err(|error| format!("AR190 cannot inspect candidate: {error}"))?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err("AR190 archive root must be a real directory".into());
        }
        for entry in WalkDir::new(root).follow_links(false) {
            let entry = entry.map_err(|error| format!("AR190 cannot walk candidate: {error}"))?;
            if entry.file_type().is_symlink()
                || (!entry.file_type().is_dir() && !entry.file_type().is_file())
            {
                return Err("AR190 archive contains a link or special file".into());
            }
        }
        Ok(Self {
            root: root.to_path_buf(),
        })
    }
}

impl Store for DirectoryStore {
    fn get(
        &mut self,
        key: &str,
        target: &Path,
        limit: u64,
        optional: bool,
    ) -> Result<Option<String>> {
        let source = self.root.join(safe_key(key)?);
        if optional && !source.exists() {
            return Ok(None);
        }
        regular_bounded(&source, limit, "local object")?;
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(io_error)?;
        }
        fs::copy(&source, target).map_err(io_error)?;
        Ok(Some(format!("\"{}\"", sha256(&source)?)))
    }

    fn empty(&self) -> Result<bool> {
        Ok(fs::read_dir(&self.root).map_err(io_error)?.next().is_none())
    }
}

pub fn prepare(
    manifest_path: &Path,
    project: Option<&str>,
    incoming: Option<&Path>,
    output: &Path,
    baseline_path: &Path,
) -> Result<()> {
    let manifest = Manifest::load(manifest_path)?;
    if output.exists() || baseline_path.exists() {
        return Err("AR190 output pool and baseline must be new paths".into());
    }
    if project.is_some() != incoming.is_some() {
        return Err("AR190 project and incoming pool must be supplied together".into());
    }
    let temporary = TempDir::new().map_err(io_error)?;
    let mut store = AwsStore::new(&manifest);
    let (prior, baseline) = restore(&manifest, &mut store, temporary.path())?;
    let mut current = Vec::new();
    if let (Some(project), Some(incoming)) = (project, incoming) {
        let selected = manifest.project(project)?;
        let allowed = selected.packages.iter().cloned().collect::<BTreeSet<_>>();
        let component = manifest.component(None)?;
        current = deb::collect(incoming, &manifest, &allowed, &component)?;
        let present = current
            .iter()
            .map(|binary| binary.package.as_str())
            .collect::<BTreeSet<_>>();
        if selected
            .packages
            .iter()
            .any(|package| !present.contains(package.as_str()))
        {
            return Err("AR190 incoming package set is incomplete".into());
        }
    }
    let old_by_id = prior
        .iter()
        .map(|binary| {
            (
                (
                    binary.package.as_str(),
                    binary.version.as_str(),
                    binary.architecture.as_str(),
                ),
                binary,
            )
        })
        .collect::<BTreeMap<_, _>>();
    for binary in &current {
        if let Some(old) = old_by_id.get(&(
            binary.package.as_str(),
            binary.version.as_str(),
            binary.architecture.as_str(),
        )) && (sha256(&old.source_path)? != sha256(&binary.source_path)?
            || old.pool_path != binary.pool_path)
        {
            return Err(format!(
                "AR190 same-version payload changed: {}",
                binary.pool_path
            ));
        }
    }
    if let Some(project) = project {
        for old in prior.iter().filter(|binary| {
            manifest
                .owner(&binary.package)
                .is_ok_and(|owner| owner.name == project)
        }) {
            let candidates = current.iter().filter(|binary| {
                binary.package == old.package && binary.architecture == old.architecture
            });
            let mut accepted = false;
            for candidate in candidates {
                let status = Command::new("dpkg")
                    .args(["--compare-versions", &candidate.version, "ge", &old.version])
                    .status()
                    .map_err(|error| format!("AR190 cannot execute dpkg: {error}"))?;
                if status.success() {
                    accepted = true;
                } else if status.code() != Some(1) {
                    return Err("AR190 cannot compare Debian versions".into());
                }
            }
            if !accepted {
                return Err("AR190 incoming import removes or rolls back an architecture".into());
            }
        }
    }
    let imported = current.len();
    let current_identities = current
        .iter()
        .map(|binary| {
            (
                binary.package.clone(),
                binary.version.clone(),
                binary.architecture.clone(),
            )
        })
        .collect::<BTreeSet<_>>();
    let mut combined = prior
        .into_iter()
        .filter(|binary| {
            !current_identities.contains(&(
                binary.package.clone(),
                binary.version.clone(),
                binary.architecture.clone(),
            ))
        })
        .collect::<Vec<_>>();
    combined.extend(current);
    let merged = if let Some(project) = project {
        prune_project(&manifest, combined, project)?
    } else {
        combined
    };
    if merged.is_empty() || merged.len() > MAX_PACKAGES {
        return Err("AR190 merged archive inventory is empty or oversized".into());
    }
    let total = merged.iter().try_fold(0u64, |sum, binary| {
        let bytes = fs::metadata(&binary.source_path).map_err(io_error)?.len();
        sum.checked_add(bytes)
            .ok_or_else(|| "AR190 aggregate size overflow".to_string())
    })?;
    if total > MAX_TOTAL {
        return Err("AR190 merged archive exceeds aggregate payload bound".into());
    }
    let staging = temporary.path().join("merged");
    fs::create_dir(&staging).map_err(io_error)?;
    for binary in &merged {
        let target = staging.join(format!(
            "{}_{}_{}.deb",
            binary.package, binary.version, binary.architecture
        ));
        if target.exists() {
            return Err("AR190 merged pool has duplicate package identities".into());
        }
        fs::copy(&binary.source_path, target).map_err(io_error)?;
    }
    let component = manifest.component(None)?;
    deb::collect(&staging, &manifest, &manifest.all_packages(), &component)?;
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(io_error)?;
    }
    fs::rename(&staging, output).map_err(io_error)?;
    write_json_new(baseline_path, &baseline)?;
    println!(
        "prepared {} domain payloads; retained {}, imported {imported}",
        merged.len(),
        merged.len() - imported
    );
    Ok(())
}

fn prune_project(manifest: &Manifest, binaries: Vec<Binary>, project: &str) -> Result<Vec<Binary>> {
    let selected = manifest.project(project)?;
    let (mut owned, mut others): (Vec<_>, Vec<_>) = binaries.into_iter().partition(|binary| {
        manifest
            .owner(&binary.package)
            .is_ok_and(|owner| owner.name == project)
    });
    let groups = owned
        .iter()
        .map(|binary| (binary.package.clone(), binary.architecture.clone()))
        .collect::<BTreeSet<_>>();
    let mut retained = BTreeSet::new();
    for (package, architecture) in groups {
        let mut candidates = owned
            .iter()
            .enumerate()
            .filter(|(_, binary)| binary.package == package && binary.architecture == architecture)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        for _ in 0..selected.keep_versions {
            let Some(mut best_position) = (!candidates.is_empty()).then_some(0usize) else {
                break;
            };
            for position in 1..candidates.len() {
                let candidate = &owned[candidates[position]];
                let best = &owned[candidates[best_position]];
                let status = Command::new("dpkg")
                    .args([
                        "--compare-versions",
                        &candidate.version,
                        "gt",
                        &best.version,
                    ])
                    .status()
                    .map_err(|error| format!("AR190 cannot execute dpkg: {error}"))?;
                if status.success() {
                    best_position = position;
                } else if status.code() != Some(1) {
                    return Err("AR190 cannot compare Debian versions".into());
                }
            }
            retained.insert(candidates.remove(best_position));
        }
    }
    for (index, binary) in owned.drain(..).enumerate() {
        if retained.contains(&index) {
            others.push(binary);
        }
    }
    Ok(others)
}

pub fn guard(
    manifest_path: &Path,
    baseline_path: &Path,
    plan_path: &Path,
) -> Result<Vec<crate::archive::PlanEntry>> {
    let manifest = Manifest::load(manifest_path)?;
    let baseline: Baseline = read_json_bounded(baseline_path, MIB)?;
    validate_baseline(&manifest, &baseline)?;
    let mut store = AwsStore::new(&manifest);
    let temporary = TempDir::new().map_err(io_error)?;
    let current = temporary.path().join("current-InRelease");
    let current_etag = store.get(
        &format!("dists/{}/InRelease", manifest.release.suite),
        &current,
        4 * MIB,
        true,
    )?;
    let current_hash = if current_etag.is_some() {
        Some(sha256(&current)?)
    } else {
        None
    };
    if current_hash != baseline.inrelease_sha256 || (current_etag.is_none() && !store.empty()?) {
        return Err("AR190 published generation changed since restore".into());
    }
    let mut plan: PublicationPlan = read_json_bounded(plan_path, MAX_STATE)?;
    if plan.meta.publication_epoch <= baseline.publication_epoch {
        return Err("AR190 candidate publication epoch is not newer than the baseline".into());
    }
    for (number, entry) in plan.entries.iter_mut().enumerate() {
        entry.skip = false;
        if entry.phase == "pool" || entry.key.contains("/by-hash/") {
            let previous = temporary.path().join(format!("object-{number}"));
            if store
                .get(&entry.key, &previous, entry.size, true)?
                .is_some()
            {
                if fs::metadata(&previous).map_err(io_error)?.len() != entry.size
                    || sha256(&previous)? != sha256(Path::new(&entry.local))?
                {
                    return Err(format!("AR190 immutable object collision: {}", entry.key));
                }
                entry.skip = true;
            }
        }
    }
    Ok(plan.entries)
}

pub fn commit_guard(manifest_path: &Path, baseline_path: &Path) -> Result<Option<String>> {
    let manifest = Manifest::load(manifest_path)?;
    let baseline: Baseline = read_json_bounded(baseline_path, MIB)?;
    validate_baseline(&manifest, &baseline)?;
    let temporary = TempDir::new().map_err(io_error)?;
    let mut store = AwsStore::new(&manifest);
    let target = temporary.path().join("InRelease");
    let etag = store.get(
        &format!("dists/{}/InRelease", manifest.release.suite),
        &target,
        4 * MIB,
        true,
    )?;
    let hash = if etag.is_some() {
        Some(sha256(&target)?)
    } else {
        None
    };
    if hash != baseline.inrelease_sha256 {
        return Err("AR190 published generation changed before commit".into());
    }
    if etag.is_some() && etag != baseline.inrelease_etag {
        return Err("AR190 generation ETag changed before commit".into());
    }
    Ok(etag)
}

pub fn verify_candidate(manifest_path: &Path, root: &Path, publication_epoch: u64) -> Result<()> {
    let manifest = Manifest::load(manifest_path)?;
    let temporary = TempDir::new().map_err(io_error)?;
    let mut store = DirectoryStore::new(root)?;
    let (binaries, baseline) = restore(&manifest, &mut store, temporary.path())?;
    if binaries.is_empty() || baseline.publication_epoch != publication_epoch {
        return Err("AR190 candidate signature does not equal publication epoch".into());
    }
    let suite = root.join("dists").join(&manifest.release.suite);
    if fs::read(temporary.path().join("Release")).map_err(io_error)?
        != fs::read(suite.join("Release")).map_err(io_error)?
    {
        return Err("AR190 candidate Release differs from signed InRelease".into());
    }
    release_time::validate(
        &manifest,
        &suite.join("Release"),
        publication_epoch,
        None,
        Some(3600),
    )?;
    let status = process::run(
        "gpgv",
        [
            "--homedir",
            temporary.path().join("gnupg").to_str().unwrap(),
            "--keyring",
            temporary.path().join("keyring.pgp").to_str().unwrap(),
            "--status-fd",
            "1",
            suite.join("Release.gpg").to_str().unwrap(),
            suite.join("Release").to_str().unwrap(),
        ],
    )?;
    validate_signature_status(&manifest, &status.stdout, Some(publication_epoch))?;
    let decoded = temporary.path().join("dearmored.pgp");
    process::run(
        "gpg",
        [
            "--no-options",
            "--batch",
            "--no-autostart",
            "--homedir",
            temporary.path().join("gnupg").to_str().unwrap(),
            "--output",
            decoded.to_str().unwrap(),
            "--dearmor",
            root.join(format!("{}.asc", manifest.domain.keyring_package))
                .to_str()
                .unwrap(),
        ],
    )?;
    if fs::read(decoded).map_err(io_error)?
        != fs::read(temporary.path().join("keyring.pgp")).map_err(io_error)?
    {
        return Err("AR190 armored and binary domain keyrings disagree".into());
    }
    let verified_indexes = temporary.path().join("indexes/SHA256");
    for entry in WalkDir::new(&verified_indexes) {
        let entry =
            entry.map_err(|error| format!("AR190 cannot walk verified indexes: {error}"))?;
        if !entry.file_type().is_file() {
            continue;
        }
        let relative = entry
            .path()
            .strip_prefix(&verified_indexes)
            .expect("walked below verified index root");
        if fs::read(entry.path()).map_err(io_error)?
            != fs::read(suite.join(relative)).map_err(io_error)?
        {
            return Err(format!(
                "AR190 mutable index differs from its signed identity: {}",
                relative.display()
            ));
        }
    }
    verify_candidate_inventory(&manifest, root, temporary.path(), &binaries)?;
    Ok(())
}

pub fn verify_publication(
    manifest_path: &Path,
    root: &Path,
    publication_epoch: u64,
    project: Option<&str>,
    base_override: Option<&str>,
) -> Result<()> {
    verify_candidate(manifest_path, root, publication_epoch)?;
    let manifest = Manifest::load(manifest_path)?;
    let plan = crate::archive::plan(&manifest, root, project, publication_epoch)?;
    let base = base_override.unwrap_or(&manifest.domain.base_url);
    static LOOPBACK: OnceLock<Regex> = OnceLock::new();
    if base != manifest.domain.base_url
        && !LOOPBACK
            .get_or_init(|| Regex::new(r"^http://127\.0\.0\.1:[1-9][0-9]{0,4}$").unwrap())
            .is_match(base)
    {
        return Err("AR160 base override is permitted only for an isolated loopback server".into());
    }
    let temporary = TempDir::new().map_err(io_error)?;
    let target = temporary.path().join("download");
    for entry in &plan.entries {
        if target.exists() {
            fs::remove_file(&target).map_err(io_error)?;
        }
        let output = Command::new("curl")
            .args([
                "--silent",
                "--show-error",
                "--fail",
                "--proto",
                "=https,http",
                "--connect-timeout",
                "10",
                "--max-time",
                "120",
                "--max-filesize",
                &entry.size.max(1).to_string(),
                "--output",
                target.to_str().unwrap(),
                &format!("{base}/{}", entry.key),
            ])
            .output()
            .map_err(|error| format!("AR160 cannot execute curl: {error}"))?;
        if !output.status.success() {
            return Err(format!(
                "AR160 cannot fetch bounded public object {}: {}",
                entry.key,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        if fs::metadata(&target).map_err(io_error)?.len() != entry.size
            || sha256(&target)? != sha256(Path::new(&entry.local))?
        {
            return Err(format!(
                "AR160 published object differs from verified local file: {}",
                entry.key
            ));
        }
    }
    println!(
        "publication verified against {base}: {} objects",
        plan.entries.len()
    );
    Ok(())
}

fn restore(
    manifest: &Manifest,
    store: &mut dyn Store,
    work: &Path,
) -> Result<(Vec<Binary>, Baseline)> {
    if manifest.release.components.len() != 1 {
        return Err("AR190 shared domain requires exactly one component".into());
    }
    let Some((state, baseline)) = verified_release(manifest, store, work)? else {
        return Ok((
            Vec::new(),
            Baseline {
                schema_version: 1,
                base_url: manifest.domain.base_url.clone(),
                suite: manifest.release.suite.clone(),
                inrelease_sha256: None,
                publication_epoch: 0,
                inrelease_etag: None,
            },
        ));
    };
    if state.packages.is_empty() || state.packages.len() > MAX_PACKAGES {
        return Err("AR190 invalid snapshot inventory".into());
    }
    let component = manifest.component(None)?;
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    let mut total = 0u64;
    for row in &state.packages {
        let owner = manifest.owner(&row.package)?;
        if owner.name != row.project || owner.source_repo != row.source_repo {
            return Err("AR190 published package ownership changed".into());
        }
        let filename = safe_key(&row.filename)?;
        if !filename.starts_with("pool/") || !seen.insert(filename.clone()) {
            return Err("AR190 duplicate or non-pool payload".into());
        }
        if row.size == 0 || row.size > 512 * MIB {
            return Err("AR190 invalid snapshot payload size".into());
        }
        total = total
            .checked_add(row.size)
            .ok_or_else(|| "AR190 snapshot size overflow".to_string())?;
        if total > MAX_TOTAL {
            return Err("AR190 snapshot exceeds aggregate bound".into());
        }
        let package = work.join("payloads").join(&filename);
        store.get(&filename, &package, row.size, false)?;
        if fs::metadata(&package).map_err(io_error)?.len() != row.size
            || sha256(&package)? != row.sha256
        {
            return Err(format!("AR190 retained payload changed: {filename}"));
        }
        let binary = Binary::parse(&package, manifest, &manifest.all_packages(), &component)?;
        if binary.pool_path != filename
            || binary.package != row.package
            || binary.version != row.version
            || binary.architecture != row.architecture
        {
            return Err(format!(
                "AR190 retained payload control identity changed: {filename}"
            ));
        }
        result.push(binary);
    }
    validate_indexes(manifest, work, &result, &component)?;
    Ok((result, baseline))
}

fn verified_release(
    manifest: &Manifest,
    store: &mut dyn Store,
    work: &Path,
) -> Result<Option<(ArchiveState, Baseline)>> {
    let suite = format!("dists/{}", manifest.release.suite);
    let inrelease = work.join("InRelease");
    let Some(etag) = store.get(&format!("{suite}/InRelease"), &inrelease, 4 * MIB, true)? else {
        if !store.empty()? {
            return Err("AR190 InRelease absent in a nonempty bucket".into());
        }
        return Ok(None);
    };
    require_fingerprints(manifest)?;
    let key = work.join("keyring.pgp");
    store.get(
        &format!("{}.pgp", manifest.domain.keyring_package),
        &key,
        MIB,
        false,
    )?;
    let home = work.join("gnupg");
    fs::create_dir(&home).map_err(io_error)?;
    set_mode(&home, 0o700)?;
    verify_keyring(manifest, &home, &key)?;
    let status = process::run(
        "gpgv",
        [
            "--homedir",
            home.to_str().unwrap(),
            "--keyring",
            key.to_str().unwrap(),
            "--status-fd",
            "1",
            inrelease.to_str().unwrap(),
        ],
    )?;
    let epoch = validate_signature_status(manifest, &status.stdout, None)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "AR190 system clock precedes Unix epoch".to_string())?
        .as_secs();
    if epoch == 0 || epoch > now {
        return Err("AR190 snapshot signature time is in the future".into());
    }
    let release = work.join("Release");
    process::run(
        "gpg",
        [
            "--no-options",
            "--batch",
            "--no-autostart",
            "--homedir",
            home.to_str().unwrap(),
            "--no-default-keyring",
            "--keyring",
            key.to_str().unwrap(),
            "--output",
            release.to_str().unwrap(),
            "--decrypt",
            inrelease.to_str().unwrap(),
        ],
    )?;
    release_time::validate(manifest, &release, epoch, Some(epoch), None)?;
    let hashes = parse_release(manifest, &release)?;
    for algorithm in ["SHA256", "SHA512"] {
        for (relative, (digest, size)) in &hashes[algorithm] {
            let parent = index_parent_prefix(Path::new(relative));
            let target = work.join("indexes").join(algorithm).join(relative);
            store.get(
                &format!("{suite}/{parent}by-hash/{algorithm}/{digest}"),
                &target,
                (*size).max(1),
                false,
            )?;
            if fs::metadata(&target).map_err(io_error)?.len() != *size
                || digest_for(&target, algorithm)? != *digest
            {
                return Err("AR190 signed index bytes changed".into());
            }
            if algorithm == "SHA512"
                && fs::read(&target).map_err(io_error)?
                    != fs::read(work.join("indexes/SHA256").join(relative)).map_err(io_error)?
            {
                return Err("AR190 signed index hash algorithms disagree".into());
            }
        }
    }
    let state: ArchiveState =
        read_json_bounded(&work.join("indexes/SHA256/archive-state.json"), MAX_STATE)?;
    if state.schema_version != 1
        || state.base_url != manifest.domain.base_url
        || state.suite != manifest.release.suite
        || state.architectures != manifest.release.architectures
        || state.component != manifest.release.components[0]
    {
        return Err("AR190 snapshot domain binding changed".into());
    }
    Ok(Some((
        state,
        Baseline {
            schema_version: 1,
            base_url: manifest.domain.base_url.clone(),
            suite: manifest.release.suite.clone(),
            inrelease_sha256: Some(sha256(&inrelease)?),
            publication_epoch: epoch,
            inrelease_etag: Some(etag),
        },
    )))
}

fn parse_release(manifest: &Manifest, release: &Path) -> Result<ReleaseHashes> {
    let text = fs::read_to_string(release).map_err(io_error)?;
    let mut headers = BTreeMap::new();
    let mut hashes = BTreeMap::from([
        ("SHA256".to_string(), BTreeMap::new()),
        ("SHA512".to_string(), BTreeMap::new()),
    ]);
    let mut section: Option<String> = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix(' ') {
            let Some(section_name) = &section else {
                return Err("AR190 unexpected Release continuation".into());
            };
            let parts = rest.split_whitespace().collect::<Vec<_>>();
            if parts.len() != 3 {
                return Err("AR190 malformed signed hash row".into());
            }
            let size = parts[1]
                .parse::<u64>()
                .map_err(|_| "AR190 invalid signed index size".to_string())?;
            if size > MAX_STATE || digest_length(section_name) != parts[0].len() {
                return Err("AR190 unsafe signed hash row".into());
            }
            safe_key(parts[2])?;
            if hashes
                .get_mut(section_name)
                .unwrap()
                .insert(parts[2].to_string(), (parts[0].to_string(), size))
                .is_some()
            {
                return Err("AR190 duplicate signed index identity".into());
            }
        } else {
            let (label, value) = line
                .split_once(':')
                .ok_or_else(|| "AR190 malformed Release header".to_string())?;
            if headers
                .insert(label.to_string(), value.trim().to_string())
                .is_some()
            {
                return Err("AR190 duplicate Release field".into());
            }
            section = hashes.contains_key(label).then(|| label.to_string());
        }
    }
    let expected = BTreeMap::from([
        ("Origin", manifest.domain.origin.clone()),
        ("Label", manifest.domain.origin.clone()),
        ("Suite", manifest.release.suite.clone()),
        ("Codename", manifest.release.codename.clone()),
        ("Architectures", manifest.release.architectures.join(" ")),
        ("Components", manifest.release.components.join(" ")),
        ("Acquire-By-Hash", "yes".to_string()),
    ]);
    for (field, value) in expected {
        if headers.get(field) != Some(&value) {
            return Err(format!("AR190 signed Release {field} changed"));
        }
    }
    let component = &manifest.release.components[0];
    let mut expected_paths = BTreeSet::from(["archive-state.json".to_string()]);
    for architecture in &manifest.release.architectures {
        for name in ["Packages", "Packages.gz"] {
            expected_paths.insert(format!("{component}/binary-{architecture}/{name}"));
        }
    }
    for values in hashes.values() {
        if values.keys().cloned().collect::<BTreeSet<_>>() != expected_paths {
            return Err("AR190 signed domain inventory is incomplete or unexpected".into());
        }
    }
    Ok(hashes)
}

fn validate_indexes(
    manifest: &Manifest,
    work: &Path,
    binaries: &[Binary],
    component: &str,
) -> Result<()> {
    for architecture in &manifest.release.architectures {
        let mut selected = binaries
            .iter()
            .filter(|binary| binary.architecture == *architecture || binary.architecture == "all")
            .collect::<Vec<_>>();
        selected.sort_by_key(|binary| (&binary.package, &binary.version));
        let mut expected = Vec::new();
        for (index, binary) in selected.iter().enumerate() {
            if index > 0 {
                expected.push(b'\n');
            }
            expected.extend(deb::stanza(binary, &work.join("payloads"))?);
        }
        let directory = work
            .join("indexes/SHA256")
            .join(component)
            .join(format!("binary-{architecture}"));
        if fs::read(directory.join("Packages")).map_err(io_error)? != expected {
            return Err("AR190 signed state and Packages index disagree".into());
        }
        let mut decoded = Vec::new();
        GzDecoder::new(File::open(directory.join("Packages.gz")).map_err(io_error)?)
            .take(MAX_STATE + 1)
            .read_to_end(&mut decoded)
            .map_err(io_error)?;
        if decoded != expected {
            return Err("AR190 compressed package index disagrees or is oversized".into());
        }
    }
    Ok(())
}

fn verify_candidate_inventory(
    manifest: &Manifest,
    root: &Path,
    work: &Path,
    binaries: &[Binary],
) -> Result<()> {
    let mut expected = binaries
        .iter()
        .map(|binary| binary.pool_path.clone())
        .collect::<BTreeSet<_>>();
    expected.insert(format!("{}.asc", manifest.domain.keyring_package));
    expected.insert(format!("{}.pgp", manifest.domain.keyring_package));
    expected.insert("index.html".into());
    for name in ["Release", "Release.gpg", "InRelease"] {
        expected.insert(format!("dists/{}/{name}", manifest.release.suite));
    }
    for entry in WalkDir::new(work.join("indexes/SHA256")) {
        let entry =
            entry.map_err(|error| format!("AR190 cannot walk verified indexes: {error}"))?;
        if !entry.file_type().is_file() {
            continue;
        }
        let relative = entry
            .path()
            .strip_prefix(work.join("indexes/SHA256"))
            .unwrap();
        expected.insert(format!(
            "dists/{}/{}",
            manifest.release.suite,
            relative.display()
        ));
        let parent = index_parent_prefix(relative);
        for algorithm in ["SHA256", "SHA512"] {
            expected.insert(format!(
                "dists/{}/{parent}by-hash/{algorithm}/{}",
                manifest.release.suite,
                digest_for(entry.path(), algorithm)?
            ));
        }
    }
    let mut actual = BTreeSet::new();
    for entry in WalkDir::new(root).follow_links(false) {
        let entry = entry.map_err(|error| format!("AR190 cannot walk candidate: {error}"))?;
        if entry.file_type().is_file() {
            actual.insert(
                entry
                    .path()
                    .strip_prefix(root)
                    .expect("walked below candidate root")
                    .to_string_lossy()
                    .to_string(),
            );
        }
    }
    if actual != expected {
        let missing = expected
            .difference(&actual)
            .take(8)
            .cloned()
            .collect::<Vec<_>>();
        let unexpected = actual
            .difference(&expected)
            .take(8)
            .cloned()
            .collect::<Vec<_>>();
        return Err(format!(
            "AR190 candidate tree contains missing or unindexed objects; missing={missing:?}, unexpected={unexpected:?}"
        ));
    }
    Ok(())
}

fn verify_keyring(manifest: &Manifest, home: &Path, key: &Path) -> Result<()> {
    let output = process::run(
        "gpg",
        [
            "--no-options",
            "--batch",
            "--no-autostart",
            "--homedir",
            home.to_str().unwrap(),
            "--with-colons",
            "--show-keys",
            "--fingerprint",
            key.to_str().unwrap(),
        ],
    )?;
    let text = String::from_utf8(output.stdout)
        .map_err(|_| "AR190 gpg key listing is not UTF-8".to_string())?;
    let mut primary = Vec::new();
    let mut subkeys = Vec::new();
    let mut destination = None;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "AR190 system clock precedes Unix epoch".to_string())?
        .as_secs();
    for line in text.lines() {
        let fields = line.split(':').collect::<Vec<_>>();
        match fields[0] {
            "sec" | "ssb" => return Err("AR190 public keyring contains secret material".into()),
            "pub" | "sub" => {
                if fields.len() < 12
                    || matches!(fields[1], "r" | "e" | "d" | "i")
                    || (!fields[6].is_empty()
                        && fields[6]
                            .parse::<u64>()
                            .map_or(true, |expiry| expiry <= now))
                    || (fields[0] == "pub"
                        && (!fields[11].contains('c') || fields[11].contains('s')))
                    || (fields[0] == "sub" && !fields[11].contains('s'))
                {
                    return Err(
                        "AR190 archive key status or capability differs from its role".into(),
                    );
                }
                destination = if fields[0] == "pub" {
                    Some(&mut primary)
                } else {
                    Some(&mut subkeys)
                };
            }
            "fpr" => {
                if let Some(values) = destination.take() {
                    values.push(fields.get(9).unwrap_or(&"").to_string());
                }
            }
            _ => {}
        }
    }
    if primary != [manifest.signing.primary_fingerprint.clone()]
        || subkeys != [manifest.signing.signing_subkey.clone()]
    {
        return Err("AR190 keyring differs from the pinned trust anchor".into());
    }
    Ok(())
}

fn validate_signature_status(
    manifest: &Manifest,
    status: &[u8],
    expected_epoch: Option<u64>,
) -> Result<u64> {
    let text = String::from_utf8(status.to_vec())
        .map_err(|_| "AR190 gpg status is not UTF-8".to_string())?;
    let valid = text
        .lines()
        .filter(|line| line.starts_with("[GNUPG:] VALIDSIG "))
        .map(|line| line.split_whitespace().collect::<Vec<_>>())
        .collect::<Vec<_>>();
    if valid.len() != 1
        || valid[0].get(2) != Some(&manifest.signing.signing_subkey.as_str())
        || valid[0].last() != Some(&manifest.signing.primary_fingerprint.as_str())
    {
        return Err("AR190 unexpected snapshot signer".into());
    }
    let epoch = valid[0]
        .get(4)
        .ok_or_else(|| "AR190 signature carries no epoch".to_string())?
        .parse::<u64>()
        .map_err(|_| "AR190 signature epoch is malformed".to_string())?;
    if expected_epoch.is_some_and(|expected| expected != epoch) {
        return Err("AR190 signature time differs from publication epoch".into());
    }
    Ok(epoch)
}

fn require_fingerprints(manifest: &Manifest) -> Result<()> {
    static FINGERPRINT: OnceLock<Regex> = OnceLock::new();
    let pattern = FINGERPRINT.get_or_init(|| Regex::new(r"^[0-9A-F]{40}$").unwrap());
    if !pattern.is_match(&manifest.signing.primary_fingerprint)
        || !pattern.is_match(&manifest.signing.signing_subkey)
    {
        return Err("AR190 signing fingerprints must be 40 uppercase hex digits".into());
    }
    Ok(())
}

fn validate_baseline(manifest: &Manifest, baseline: &Baseline) -> Result<()> {
    if baseline.schema_version != 1
        || baseline.base_url != manifest.domain.base_url
        || baseline.suite != manifest.release.suite
    {
        return Err("AR190 baseline does not belong to this domain".into());
    }
    Ok(())
}

fn read_json_bounded<T: DeserializeOwned>(path: &Path, limit: u64) -> Result<T> {
    regular_bounded(path, limit, "JSON input")?;
    let bytes = fs::read(path).map_err(io_error)?;
    serde_json::from_slice(&bytes).map_err(|error| format!("AR190 invalid JSON: {error}"))
}

fn write_json_new<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if path.exists() {
        return Err(format!("AR190 output must be new: {}", path.display()));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error)?;
    }
    let mut bytes =
        serde_json::to_vec(value).map_err(|error| format!("AR190 cannot encode JSON: {error}"))?;
    bytes.push(b'\n');
    fs::write(path, bytes).map_err(io_error)
}

fn regular_bounded(path: &Path, limit: u64, label: &str) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("AR190 cannot inspect {label}: {error}"))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > limit {
        return Err(format!("AR190 {label} is not a bounded regular file"));
    }
    Ok(metadata)
}

fn safe_key(key: &str) -> Result<String> {
    static PART: OnceLock<Regex> = OnceLock::new();
    let pattern = PART.get_or_init(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._+~:-]*$").unwrap());
    let path = Path::new(key);
    if key.is_empty()
        || key.starts_with('/')
        || path
            .components()
            .any(|part| !matches!(part, Component::Normal(value) if pattern.is_match(&value.to_string_lossy())))
    {
        return Err(format!("AR190 unsafe object key: {key:?}"));
    }
    Ok(key.to_string())
}

fn digest_for(path: &Path, algorithm: &str) -> Result<String> {
    let bytes = fs::read(path).map_err(io_error)?;
    Ok(if algorithm == "SHA256" {
        format!("{:x}", Sha256::digest(bytes))
    } else {
        format!("{:x}", Sha512::digest(bytes))
    })
}

fn index_parent_prefix(relative: &Path) -> String {
    relative
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .map_or_else(String::new, |path| format!("{}/", path.display()))
}

fn digest_length(algorithm: &str) -> usize {
    if algorithm == "SHA256" { 64 } else { 128 }
}

fn sha256(path: &Path) -> Result<String> {
    digest_for(path, "SHA256")
}

fn io_error(error: std::io::Error) -> String {
    format!("AR190 filesystem error: {error}")
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(io_error)
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod path_tests {
    use super::index_parent_prefix;
    use std::path::Path;

    #[test]
    fn by_hash_parent_prefix_handles_root_and_nested_indexes() {
        assert_eq!(index_parent_prefix(Path::new("archive-state.json")), "");
        assert_eq!(
            index_parent_prefix(Path::new("main/binary-amd64/Packages")),
            "main/binary-amd64/"
        );
    }
}
