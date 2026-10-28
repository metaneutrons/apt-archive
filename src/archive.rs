use crate::{
    deb::{self, Binary},
    manifest::{Manifest, Result},
    release_time,
};
use flate2::{Compression, GzBuilder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256, Sha512};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    path::{Path, PathBuf},
};
use walkdir::WalkDir;

pub const LANDING_PAGE_NAME: &str = "index.html";
const RELEASE_FILES: [&str; 3] = ["Release", "Release.gpg", "InRelease"];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArchiveState {
    pub schema_version: u32,
    pub base_url: String,
    pub suite: String,
    pub architectures: Vec<String>,
    pub component: String,
    pub packages: Vec<StatePackage>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatePackage {
    pub project: String,
    pub source_repo: String,
    pub package: String,
    pub version: String,
    pub architecture: String,
    pub filename: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlanMeta {
    pub bucket: String,
    pub account_id: String,
    pub host: String,
    pub base_url: String,
    pub keyring_package: String,
    pub suite: String,
    pub publication_epoch: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlanEntry {
    pub phase: String,
    pub local: String,
    pub key: String,
    pub content_type: String,
    pub size: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub skip: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublicationPlan {
    pub meta: PlanMeta,
    pub entries: Vec<PlanEntry>,
}

pub fn render(
    manifest: &Manifest,
    pool: &Path,
    output: &Path,
    component: &str,
    epoch: u64,
) -> Result<()> {
    if epoch == 0 {
        return Err("AR100 publication-epoch must be positive".into());
    }
    if fs::symlink_metadata(output).is_ok() {
        return Err(format!(
            "AR100 output-dir must be a new path: {}",
            output.display()
        ));
    }
    let binaries = deb::collect(pool, manifest, &manifest.all_packages(), component)?;
    fs::create_dir_all(output).map_err(io_error)?;
    set_mode(output, 0o755)?;
    for binary in &binaries {
        let target = output.join(&binary.pool_path);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(io_error)?;
        }
        fs::copy(&binary.source_path, &target).map_err(io_error)?;
        set_mode(&target, 0o644)?;
    }
    let dists = output.join("dists").join(&manifest.release.suite);
    fs::create_dir_all(&dists).map_err(io_error)?;
    let mut state_packages = Vec::new();
    let mut sorted = binaries.iter().collect::<Vec<_>>();
    sorted.sort_by_key(|binary| (&binary.package, &binary.version, &binary.architecture));
    for binary in sorted {
        let owner = manifest.owner(&binary.package)?;
        let target = output.join(&binary.pool_path);
        let (size, sha256, _) = deb::file_hashes(&target)?;
        state_packages.push(StatePackage {
            project: owner.name.clone(),
            source_repo: owner.source_repo.clone(),
            package: binary.package.clone(),
            version: binary.version.clone(),
            architecture: binary.architecture.clone(),
            filename: binary.pool_path.clone(),
            size,
            sha256,
        });
    }
    let state = ArchiveState {
        schema_version: 1,
        base_url: manifest.domain.base_url.clone(),
        suite: manifest.release.suite.clone(),
        architectures: manifest.release.architectures.clone(),
        component: component.to_string(),
        packages: state_packages,
    };
    let state_path = dists.join("archive-state.json");
    write_json(&state_path, &state)?;
    write_by_hash(&state_path, &dists)?;

    let portable = binaries
        .iter()
        .filter(|binary| binary.architecture == "all")
        .collect::<Vec<_>>();
    for architecture in &manifest.release.architectures {
        let mut selected = binaries
            .iter()
            .filter(|binary| binary.architecture == *architecture)
            .collect::<Vec<_>>();
        selected.extend(portable.iter().copied());
        selected.sort_by_key(|binary| (&binary.package, &binary.version));
        let directory = dists.join(component).join(format!("binary-{architecture}"));
        fs::create_dir_all(&directory).map_err(io_error)?;
        let packages = directory.join("Packages");
        let mut contents = Vec::new();
        for (index, binary) in selected.iter().enumerate() {
            if index > 0 {
                contents.push(b'\n');
            }
            contents.extend(deb::stanza(binary, output)?);
        }
        fs::write(&packages, contents).map_err(io_error)?;
        set_mode(&packages, 0o644)?;
        let compressed = directory.join("Packages.gz");
        let source = File::open(&packages).map_err(io_error)?;
        let target = File::create(&compressed).map_err(io_error)?;
        let mut encoder = GzBuilder::new()
            .filename("")
            .mtime(0)
            .write(target, Compression::best());
        std::io::copy(&mut std::io::BufReader::new(source), &mut encoder).map_err(io_error)?;
        encoder.finish().map_err(io_error)?;
        set_mode(&compressed, 0o644)?;
        write_by_hash(&packages, &directory)?;
        write_by_hash(&compressed, &directory)?;
    }

    let page = output.join(LANDING_PAGE_NAME);
    fs::write(&page, landing_page(manifest, &binaries, component)).map_err(io_error)?;
    set_mode(&page, 0o644)?;

    let mut indexes = regular_files(&dists)?;
    indexes.retain(|path| {
        !path
            .strip_prefix(&dists)
            .expect("walked below dists")
            .components()
            .any(|part| part.as_os_str() == "by-hash")
    });
    indexes.sort();
    let mut lines = vec![
        format!("Origin: {}", manifest.domain.origin),
        format!("Label: {}", manifest.domain.origin),
        format!("Suite: {}", manifest.release.suite),
        format!("Codename: {}", manifest.release.codename),
        format!(
            "Architectures: {}",
            manifest.release.architectures.join(" ")
        ),
        format!("Components: {component}"),
        "Acquire-By-Hash: yes".into(),
        format!("Description: Packages for {}", manifest.domain.host),
        format!("Date: {}", release_time::rfc2822(epoch)?),
        format!(
            "Valid-Until: {}",
            release_time::rfc2822(
                epoch
                    .checked_add(manifest.release.valid_until_days * 86_400)
                    .ok_or_else(|| "AR120 Valid-Until overflow".to_string())?,
            )?
        ),
    ];
    for algorithm in ["SHA256", "SHA512"] {
        lines.push(format!("{algorithm}:"));
        for index in &indexes {
            let bytes = fs::read(index).map_err(io_error)?;
            let digest = digest_bytes(&bytes, algorithm);
            let relative = index
                .strip_prefix(&dists)
                .expect("walked below dists")
                .to_string_lossy();
            lines.push(format!(" {digest} {:16} {relative}", bytes.len()));
        }
    }
    let release = dists.join("Release");
    fs::write(&release, format!("{}\n", lines.join("\n"))).map_err(io_error)?;
    set_mode(&release, 0o644)?;
    Ok(())
}

pub fn plan(
    manifest: &Manifest,
    archive: &Path,
    project: Option<&str>,
    epoch: u64,
) -> Result<PublicationPlan> {
    if let Some(project) = project {
        manifest.project(project)?;
    }
    let metadata = fs::symlink_metadata(archive)
        .map_err(|error| format!("AR140 cannot inspect archive: {error}"))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("AR140 archive-dir must be a real directory".into());
    }
    let canonical = archive.canonicalize().map_err(io_error)?;
    let dists = canonical.join("dists").join(&manifest.release.suite);
    for name in RELEASE_FILES {
        require_regular(&dists.join(name), "AR140 archive is not signed")?;
    }
    let mut entries = Vec::new();
    for suffix in [".asc", ".pgp"] {
        let key = format!("{}{suffix}", manifest.domain.keyring_package);
        add_entry(&mut entries, "keyring", &canonical.join(&key), &key)?;
    }
    let mut pool = regular_files(&canonical.join("pool"))?;
    pool.sort();
    for path in pool {
        let key = path
            .strip_prefix(&canonical)
            .expect("walked below archive")
            .to_string_lossy()
            .to_string();
        add_entry(&mut entries, "pool", &path, &key)?;
    }
    let release_paths = RELEASE_FILES
        .iter()
        .map(|name| dists.join(name))
        .collect::<BTreeSet<_>>();
    let mut indexes = regular_files(&dists)?;
    indexes.retain(|path| !release_paths.contains(path));
    indexes.sort();
    for path in indexes {
        let key = path
            .strip_prefix(&canonical)
            .expect("walked below archive")
            .to_string_lossy()
            .to_string();
        add_entry(&mut entries, "indexes", &path, &key)?;
    }
    add_entry(
        &mut entries,
        "page",
        &canonical.join(LANDING_PAGE_NAME),
        LANDING_PAGE_NAME,
    )?;
    for name in RELEASE_FILES {
        let path = dists.join(name);
        let key = path
            .strip_prefix(&canonical)
            .expect("below archive")
            .to_string_lossy()
            .to_string();
        add_entry(&mut entries, "release", &path, &key)?;
    }
    let mut seen = BTreeSet::new();
    if entries.iter().any(|entry| !seen.insert(entry.key.clone())) {
        return Err("AR140 two local files map to one object key".into());
    }
    release_time::validate(manifest, &dists.join("Release"), epoch, None, Some(3600))?;
    Ok(PublicationPlan {
        meta: PlanMeta {
            bucket: manifest.publication.r2_bucket.clone(),
            account_id: manifest.publication.r2_account_id.clone(),
            host: manifest.domain.host.clone(),
            base_url: manifest.domain.base_url.clone(),
            keyring_package: manifest.domain.keyring_package.clone(),
            suite: manifest.release.suite.clone(),
            publication_epoch: epoch,
        },
        entries,
    })
}

fn add_entry(entries: &mut Vec<PlanEntry>, phase: &str, path: &Path, key: &str) -> Result<()> {
    let metadata = require_regular(path, "AR140 not a regular file")?;
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let content_type = if phase == "keyring" {
        if extension == "asc" {
            "text/plain; charset=utf-8"
        } else {
            "application/pgp-keys"
        }
    } else if phase == "indexes" && path.to_string_lossy().contains("/by-hash/") {
        "application/octet-stream"
    } else {
        match extension {
            "deb" => "application/vnd.debian.binary-package",
            "gz" => "application/gzip",
            "html" => "text/html; charset=utf-8",
            _ => "text/plain; charset=utf-8",
        }
    };
    entries.push(PlanEntry {
        phase: phase.into(),
        local: path.to_string_lossy().to_string(),
        key: key.into(),
        content_type: content_type.into(),
        size: metadata.len(),
        skip: false,
    });
    Ok(())
}

fn regular_files(root: &Path) -> Result<Vec<PathBuf>> {
    let metadata = fs::symlink_metadata(root)
        .map_err(|error| format!("AR100 cannot inspect {}: {error}", root.display()))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(format!(
            "AR100 expected a real directory: {}",
            root.display()
        ));
    }
    let mut paths = Vec::new();
    for entry in WalkDir::new(root).follow_links(false) {
        let entry =
            entry.map_err(|error| format!("AR100 cannot walk {}: {error}", root.display()))?;
        if entry.path() == root {
            continue;
        }
        if entry.file_type().is_symlink()
            || (!entry.file_type().is_dir() && !entry.file_type().is_file())
        {
            return Err(format!(
                "AR100 archive contains a link or special file: {}",
                entry.path().display()
            ));
        }
        if entry.file_type().is_file() {
            paths.push(entry.path().to_path_buf());
        }
    }
    Ok(paths)
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| format!("AR100 cannot encode JSON: {error}"))?;
    bytes.push(b'\n');
    fs::write(path, bytes).map_err(io_error)?;
    set_mode(path, 0o644)
}

fn write_by_hash(path: &Path, directory: &Path) -> Result<()> {
    let bytes = fs::read(path).map_err(io_error)?;
    for algorithm in ["SHA256", "SHA512"] {
        let target_directory = directory.join("by-hash").join(algorithm);
        fs::create_dir_all(&target_directory).map_err(io_error)?;
        let target = target_directory.join(digest_bytes(&bytes, algorithm));
        fs::write(&target, &bytes).map_err(io_error)?;
        set_mode(&target, 0o644)?;
    }
    Ok(())
}

fn digest_bytes(bytes: &[u8], algorithm: &str) -> String {
    if algorithm == "SHA256" {
        format!("{:x}", Sha256::digest(bytes))
    } else {
        format!("{:x}", Sha512::digest(bytes))
    }
}

fn landing_page(manifest: &Manifest, binaries: &[Binary], component: &str) -> String {
    let mut rows: BTreeMap<&str, (BTreeSet<&str>, BTreeSet<&str>)> = BTreeMap::new();
    for binary in binaries {
        let row = rows.entry(&binary.package).or_default();
        row.0.insert(&binary.version);
        row.1.insert(&binary.architecture);
    }
    let domain = &manifest.domain;
    let release = &manifest.release;
    let mut lines = vec![
        "<!DOCTYPE html>".to_string(),
        "<html lang=\"en\"><head><meta charset=\"utf-8\">".to_string(),
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">".to_string(),
        format!("<title>{}</title></head><body>", escape(&domain.host)),
        format!("<h1>{}</h1>", escape(&domain.host)),
        format!(
            "<p>An APT archive signed by {}. Suite <code>{}</code>, component <code>{}</code>, architectures {}.</p>",
            escape(&domain.origin),
            escape(&release.suite),
            escape(component),
            escape(&release.architectures.join(" and "))
        ),
        "<h2>1. Fetch the keyring and check it</h2><pre>".to_string(),
        format!(
            "curl -fsSL -o /tmp/{}.pgp \\\\",
            escape(&domain.keyring_package)
        ),
        format!(
            "  {}/{}.pgp",
            escape(&domain.base_url),
            escape(&domain.keyring_package)
        ),
        format!(
            "gpg --show-keys --with-fingerprint /tmp/{}.pgp</pre>",
            escape(&domain.keyring_package)
        ),
        format!(
            "<table><tbody><tr><th>Primary key, offline</th><td><code>{}</code></td></tr><tr><th>Signing subkey</th><td><code>{}</code></td></tr></tbody></table>",
            escape(&manifest.signing.primary_fingerprint),
            escape(&manifest.signing.signing_subkey)
        ),
        "<h2>2. Install it and add the source</h2><pre>".to_string(),
        format!(
            "sudo install -m 0644 /tmp/{}.pgp {}",
            escape(&domain.keyring_package),
            escape(&domain.keyring_file)
        ),
        format!(
            "sudo tee /etc/apt/sources.list.d/{}.sources &gt;/dev/null &lt;&lt;'EOF'",
            escape(&domain.host)
        ),
        "Types: deb".to_string(),
        format!("URIs: {}", escape(&domain.base_url)),
        format!("Suites: {}", escape(&release.suite)),
        format!("Components: {}", escape(component)),
        format!("Signed-By: {}", escape(&domain.keyring_file)),
        "EOF".to_string(),
        "sudo apt update</pre><h2>Packages</h2>".to_string(),
        "<table><thead><tr><th>Package</th><th>Versions</th><th>Architectures</th><th>Source</th></tr></thead><tbody>".to_string(),
    ];
    for (package, (versions, architectures)) in rows {
        let owner = manifest.owner(package).expect("validated owner");
        lines.push(format!(
            "<tr><td><code>{}</code></td><td>{}</td><td>{}</td><td><a href=\"https://github.com/{}\">{}</a></td></tr>",
            escape(package),
            escape(&versions.into_iter().collect::<Vec<_>>().join(", ")),
            escape(&architectures.into_iter().collect::<Vec<_>>().join(", ")),
            escape(&owner.source_repo),
            escape(&owner.source_repo)
        ));
    }
    lines.push(format!(
        "</tbody></table><p>The signed metadata under <code>dists/{}/</code> is authoritative; this page is a convenience and is not signed.</p></body></html>",
        escape(&release.suite)
    ));
    format!("{}\n", lines.join("\n"))
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
}

fn require_regular(path: &Path, message: &str) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("{message}: {}: {error}", path.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(format!("{message}: {}", path.display()));
    }
    Ok(metadata)
}

fn io_error(error: std::io::Error) -> String {
    format!("AR100 filesystem error: {error}")
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
