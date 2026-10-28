use crate::manifest::{Manifest, Result};
use bzip2::read::BzDecoder;
use flate2::read::GzDecoder;
use regex::Regex;
use sha2::{Digest, Sha256, Sha512};
use std::{
    collections::BTreeSet,
    fs::{self, File},
    io::{Cursor, Read},
    path::{Path, PathBuf},
    sync::OnceLock,
};
use xz2::read::XzDecoder;

const MAX_DEB_BYTES: u64 = 512 * 1024 * 1024;
const MAX_CONTROL_ARCHIVE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_CONTROL_TAR_BYTES: u64 = 16 * 1024 * 1024;
const MAX_CONTROL_BYTES: u64 = 256 * 1024;
const MAX_TAR_MEMBERS: usize = 1_024;
const MAX_TAR_REGULAR_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct Binary {
    pub source_path: PathBuf,
    pub fields: Vec<(String, String)>,
    pub package: String,
    pub version: String,
    pub architecture: String,
    pub pool_path: String,
}

impl Binary {
    pub fn parse(
        path: &Path,
        manifest: &Manifest,
        allowed_packages: &BTreeSet<String>,
        component: &str,
    ) -> Result<Self> {
        let text = control_text(path)?;
        let fields = parse_fields(&text, &path.display().to_string())?;
        for computed in ["filename", "size", "sha256", "sha512"] {
            if fields
                .iter()
                .any(|(name, _)| name.eq_ignore_ascii_case(computed))
            {
                return Err(format!(
                    "AR100 {} supplies archive-computed field {computed}",
                    path.display()
                ));
            }
        }
        let value = |name: &str| -> Result<String> {
            fields
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
                .ok_or_else(|| format!("AR100 {} has no {name} field", path.display()))
        };
        let package = value("Package")?;
        let version = value("Version")?;
        let architecture = value("Architecture")?;
        static PACKAGE: OnceLock<Regex> = OnceLock::new();
        static VERSION: OnceLock<Regex> = OnceLock::new();
        static ARCH: OnceLock<Regex> = OnceLock::new();
        let package_re = PACKAGE.get_or_init(|| Regex::new(r"^[a-z0-9][a-z0-9+.-]+$").unwrap());
        let version_re =
            VERSION.get_or_init(|| Regex::new(r"^(?:[0-9]+:)?[0-9][A-Za-z0-9.+~:-]*$").unwrap());
        let arch_re = ARCH.get_or_init(|| Regex::new(r"^[a-z0-9][a-z0-9-]*$").unwrap());
        if !package_re.is_match(&package)
            || !version_re.is_match(&version)
            || !arch_re.is_match(&architecture)
        {
            return Err(format!(
                "AR100 {} has an unsafe package identity",
                path.display()
            ));
        }
        if !allowed_packages.contains(&package) {
            return Err(format!("AR100 {package:?} is not declared for this import"));
        }
        if architecture != "all" && !manifest.release.architectures.contains(&architecture) {
            return Err(format!("AR100 architecture {architecture:?} is not served"));
        }
        let source = fields
            .iter()
            .find(|(name, _)| name == "Source")
            .map_or_else(
                || package.clone(),
                |(_, value)| {
                    value
                        .split_once(' ')
                        .map_or(value.as_str(), |pair| pair.0)
                        .to_string()
                },
            );
        if !package_re.is_match(&source) {
            return Err(format!("AR100 unsafe source package name {source:?}"));
        }
        let letter = if source.starts_with("lib") {
            &source[..source.len().min(4)]
        } else {
            &source[..1]
        };
        let pool_path =
            format!("pool/{component}/{letter}/{source}/{package}_{version}_{architecture}.deb");
        Ok(Self {
            source_path: path.to_path_buf(),
            fields,
            package,
            version,
            architecture,
            pool_path,
        })
    }
}

pub fn collect(
    pool: &Path,
    manifest: &Manifest,
    allowed: &BTreeSet<String>,
    component: &str,
) -> Result<Vec<Binary>> {
    let metadata = fs::symlink_metadata(pool)
        .map_err(|error| format!("AR100 cannot inspect {}: {error}", pool.display()))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(format!(
            "AR100 pool must be a real directory: {}",
            pool.display()
        ));
    }
    let mut paths = fs::read_dir(pool)
        .map_err(|error| format!("AR100 cannot read pool: {error}"))?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<std::io::Result<Vec<_>>>()
        .map_err(|error| format!("AR100 cannot enumerate pool: {error}"))?;
    paths.sort();
    paths.retain(|path| path.extension().is_some_and(|extension| extension == "deb"));
    if paths.is_empty() {
        return Err(format!("AR100 {} contains no .deb file", pool.display()));
    }
    let mut binaries = Vec::new();
    let mut identities = BTreeSet::new();
    for path in paths {
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("AR100 cannot inspect {}: {error}", path.display()))?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(format!("AR100 {} is not a regular file", path.display()));
        }
        let binary = Binary::parse(&path, manifest, allowed, component)?;
        let identity = (
            binary.package.clone(),
            binary.version.clone(),
            binary.architecture.clone(),
        );
        if !identities.insert(identity) {
            return Err(format!(
                "AR100 duplicate package identity in {}",
                path.display()
            ));
        }
        binaries.push(binary);
    }
    let portable = binaries
        .iter()
        .filter(|binary| binary.architecture == "all")
        .map(|binary| (&binary.package, &binary.version))
        .collect::<BTreeSet<_>>();
    let native = binaries
        .iter()
        .filter(|binary| binary.architecture != "all")
        .map(|binary| (&binary.package, &binary.version))
        .collect::<BTreeSet<_>>();
    if let Some((package, version)) = portable.intersection(&native).next() {
        return Err(format!(
            "AR100 {package} {version} is both portable and native"
        ));
    }
    Ok(binaries)
}

fn control_text(path: &Path) -> Result<String> {
    let metadata = fs::metadata(path)
        .map_err(|error| format!("AR100 cannot inspect {}: {error}", path.display()))?;
    if metadata.len() <= 8 || metadata.len() > MAX_DEB_BYTES {
        return Err(format!(
            "AR100 {} size is outside the safe range",
            path.display()
        ));
    }
    let file = File::open(path)
        .map_err(|error| format!("AR100 cannot read {}: {error}", path.display()))?;
    let mut archive = ar::Archive::new(file);
    let mut control = None;
    let mut count = 0usize;
    let mut names = BTreeSet::new();
    while let Some(entry) = archive.next_entry() {
        count += 1;
        if count > 64 {
            return Err(format!("AR100 {} has too many ar members", path.display()));
        }
        let mut entry = entry
            .map_err(|error| format!("AR100 malformed ar archive {}: {error}", path.display()))?;
        let name = String::from_utf8(entry.header().identifier().to_vec())
            .map_err(|_| format!("AR100 {} has a non-UTF-8 ar member", path.display()))?;
        let name = name.trim_end_matches('/').trim().to_string();
        if name.is_empty() || !names.insert(name.clone()) {
            return Err(format!(
                "AR100 {} repeats or omits an ar member name",
                path.display()
            ));
        }
        if name.starts_with("control.tar") {
            if control.is_some() || entry.header().size() > MAX_CONTROL_ARCHIVE_BYTES {
                return Err(format!(
                    "AR100 {} must contain one bounded control archive",
                    path.display()
                ));
            }
            let mut bytes = Vec::with_capacity(usize::try_from(entry.header().size()).unwrap_or(0));
            entry
                .read_to_end(&mut bytes)
                .map_err(|error| format!("AR100 cannot read control archive: {error}"))?;
            control = Some((name, bytes));
        }
    }
    let (name, bytes) =
        control.ok_or_else(|| format!("AR100 {} has no control archive", path.display()))?;
    let decoder: Box<dyn Read> = match name.as_str() {
        "control.tar" => Box::new(Cursor::new(bytes)),
        value if value.ends_with(".gz") => Box::new(GzDecoder::new(Cursor::new(bytes))),
        value if value.ends_with(".xz") => Box::new(XzDecoder::new(Cursor::new(bytes))),
        value if value.ends_with(".bz2") => Box::new(BzDecoder::new(Cursor::new(bytes))),
        value if value.ends_with(".zst") => Box::new(
            zstd::stream::read::Decoder::new(Cursor::new(bytes))
                .map_err(|error| format!("AR100 cannot open zstd control archive: {error}"))?,
        ),
        _ => {
            return Err(format!(
                "AR100 unsupported Debian control compression: {name}"
            ));
        }
    };
    let mut tar_bytes = Vec::new();
    decoder
        .take(MAX_CONTROL_TAR_BYTES + 1)
        .read_to_end(&mut tar_bytes)
        .map_err(|error| format!("AR100 cannot decompress control archive: {error}"))?;
    if u64::try_from(tar_bytes.len()).unwrap_or(u64::MAX) > MAX_CONTROL_TAR_BYTES {
        return Err("AR100 expanded control archive exceeds its bound".into());
    }
    let mut tar = tar::Archive::new(Cursor::new(tar_bytes));
    let mut control_data = None;
    let mut members = 0usize;
    let mut regular_bytes = 0u64;
    for entry in tar
        .entries()
        .map_err(|error| format!("AR100 malformed control tar: {error}"))?
    {
        members += 1;
        if members > MAX_TAR_MEMBERS {
            return Err("AR100 control archive has too many members".into());
        }
        let mut entry =
            entry.map_err(|error| format!("AR100 malformed control member: {error}"))?;
        let member_path = entry
            .path()
            .map_err(|error| format!("AR100 unsafe control path: {error}"))?;
        if entry.header().entry_type().is_file() {
            regular_bytes = regular_bytes
                .checked_add(entry.size())
                .ok_or_else(|| "AR100 control archive size overflow".to_string())?;
            if regular_bytes > MAX_TAR_REGULAR_BYTES {
                return Err("AR100 control archive regular-file total exceeds its bound".into());
            }
        }
        if member_path == Path::new("control") || member_path == Path::new("./control") {
            if control_data.is_some()
                || !entry.header().entry_type().is_file()
                || entry.size() > MAX_CONTROL_BYTES
            {
                return Err("AR100 control metadata must be one bounded regular file".into());
            }
            let mut bytes = Vec::new();
            entry
                .read_to_end(&mut bytes)
                .map_err(|error| format!("AR100 cannot read control metadata: {error}"))?;
            control_data = Some(bytes);
        }
    }
    let bytes =
        control_data.ok_or_else(|| "AR100 control archive has no control file".to_string())?;
    let text =
        String::from_utf8(bytes).map_err(|_| "AR100 control metadata is not UTF-8".to_string())?;
    let text = text.replace("\r\n", "\n");
    if text.contains('\0') || !text.ends_with('\n') {
        return Err("AR100 unsafe Debian control metadata".into());
    }
    Ok(text.trim_end_matches('\n').to_string())
}

fn parse_fields(text: &str, origin: &str) -> Result<Vec<(String, String)>> {
    static FIELD: OnceLock<Regex> = OnceLock::new();
    let field = FIELD.get_or_init(|| Regex::new(r"^[A-Za-z0-9-]+$").unwrap());
    let mut result: Vec<(String, String)> = Vec::new();
    let mut names = BTreeSet::new();
    for line in text.lines() {
        if line.starts_with([' ', '\t']) {
            let (_, value) = result
                .last_mut()
                .ok_or_else(|| format!("AR100 {origin}: continuation without field"))?;
            value.push('\n');
            value.push_str(line);
            continue;
        }
        let (name, value) = line
            .split_once(": ")
            .ok_or_else(|| format!("AR100 {origin}: malformed field"))?;
        if !field.is_match(name) || !names.insert(name.to_ascii_lowercase()) {
            return Err(format!(
                "AR100 {origin}: unsafe or duplicate field {name:?}"
            ));
        }
        result.push((name.to_string(), value.to_string()));
    }
    Ok(result)
}

pub fn file_hashes(path: &Path) -> Result<(u64, String, String)> {
    let mut file = File::open(path)
        .map_err(|error| format!("AR100 cannot hash {}: {error}", path.display()))?;
    let mut sha256 = Sha256::new();
    let mut sha512 = Sha512::new();
    let mut size = 0u64;
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("AR100 cannot hash {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        size = size
            .checked_add(u64::try_from(read).unwrap())
            .ok_or_else(|| "AR100 file size overflow".to_string())?;
        sha256.update(&buffer[..read]);
        sha512.update(&buffer[..read]);
    }
    Ok((
        size,
        format!("{:x}", sha256.finalize()),
        format!("{:x}", sha512.finalize()),
    ))
}

pub fn stanza(binary: &Binary, archive_root: &Path) -> Result<Vec<u8>> {
    let path = archive_root.join(&binary.pool_path);
    let (size, sha256, sha512) = file_hashes(&path)?;
    let mut lines = binary
        .fields
        .iter()
        .map(|(name, value)| format!("{name}: {value}"))
        .collect::<Vec<_>>();
    lines.push(format!("Filename: {}", binary.pool_path));
    lines.push(format!("Size: {size}"));
    lines.push(format!("SHA256: {sha256}"));
    lines.push(format!("SHA512: {sha512}"));
    Ok(format!("{}\n", lines.join("\n")).into_bytes())
}
