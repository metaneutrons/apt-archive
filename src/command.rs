use crate::{
    archive, handoff,
    manifest::{Manifest, Result},
    release_time, snapshot,
};
use clap::{Parser, Subcommand, ValueEnum};
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{self, Read},
    path::PathBuf,
    sync::OnceLock,
};

#[derive(Parser)]
#[command(
    name = "apt-archive-tool",
    version,
    about = "Rust production tool for the shared APT archives"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Target {
        #[arg(long)]
        manifest: PathBuf,
    },
    Signing {
        #[arg(long)]
        manifest: PathBuf,
    },
    Project {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        project: String,
    },
    ValidateRequest {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        project: Option<String>,
    },
    SelectTags {
        #[arg(long)]
        keep: usize,
    },
    SelectAssets {
        #[arg(long, value_delimiter = ',')]
        packages: Vec<String>,
        #[arg(long, value_delimiter = ',')]
        architectures: Vec<String>,
    },
    AssetDigest {
        #[arg(long)]
        name: String,
    },
    HandoffSelect {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        project: String,
        #[arg(long)]
        handoff: PathBuf,
        #[arg(long)]
        version: String,
    },
    Render {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        pool_dir: PathBuf,
        #[arg(long)]
        output_dir: PathBuf,
        #[arg(long)]
        publication_epoch: u64,
        #[arg(long)]
        component: Option<String>,
    },
    ReleaseTime {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        release: PathBuf,
        #[arg(long)]
        publication_epoch: u64,
        #[arg(long)]
        now_epoch: Option<u64>,
        #[arg(long)]
        max_age_seconds: Option<u64>,
    },
    Plan {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        archive_dir: PathBuf,
        #[arg(long)]
        publication_epoch: u64,
        #[arg(long, value_enum, default_value_t = OutputFormat::Tsv)]
        format: OutputFormat,
    },
    SnapshotPrepare {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        baseline: PathBuf,
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        incoming_pool: Option<PathBuf>,
        #[arg(long)]
        output_pool: PathBuf,
    },
    SnapshotGuard {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        baseline: PathBuf,
        #[arg(long)]
        plan: PathBuf,
    },
    SnapshotCommitGuard {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        baseline: PathBuf,
    },
    VerifyCandidate {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        archive_dir: PathBuf,
        #[arg(long)]
        publication_epoch: u64,
    },
    VerifyPublication {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        archive_dir: PathBuf,
        #[arg(long)]
        publication_epoch: u64,
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long)]
        local_only: bool,
    },
}

#[derive(Copy, Clone, Eq, PartialEq, ValueEnum)]
enum OutputFormat {
    Tsv,
    Json,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReleaseListing {
    #[serde(rename = "tagName")]
    tag_name: String,
    #[serde(rename = "isDraft")]
    is_draft: bool,
    #[serde(rename = "isPrerelease")]
    is_prerelease: bool,
    #[serde(rename = "publishedAt")]
    published_at: Option<String>,
}

#[derive(Deserialize)]
struct AssetRelease {
    #[serde(rename = "tagName")]
    tag_name: String,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
}

pub fn run() -> Result<()> {
    match Cli::parse().command {
        Commands::Target { manifest } => {
            let manifest = Manifest::load(&manifest)?;
            println!(
                "{}\t{}",
                manifest.publication.r2_bucket, manifest.publication.r2_account_id
            );
        }
        Commands::Signing { manifest } => {
            let manifest = Manifest::load(&manifest)?;
            if manifest.signing.primary_fingerprint == "TBD"
                || manifest.signing.signing_subkey == "TBD"
            {
                return Err("AR130 signing values are still TBD".into());
            }
            println!(
                "{}\t{}\t{}\t{}",
                manifest.signing.primary_fingerprint,
                manifest.signing.signing_subkey,
                manifest.release.suite,
                manifest.domain.keyring_package
            );
        }
        Commands::Project { manifest, project } => {
            let manifest = Manifest::load(&manifest)?;
            let selected = manifest.project(&project)?;
            println!(
                "{}\t{}\t{}\t{}",
                selected.source_repo,
                selected.packages.join(","),
                manifest.release.architectures.join(","),
                selected.keep_versions
            );
        }
        Commands::ValidateRequest { manifest, project } => {
            let manifest = Manifest::load(&manifest)?;
            if let Some(project) = project.as_deref().filter(|value| !value.is_empty()) {
                manifest.project(project)?;
            }
        }
        Commands::SelectTags { keep } => select_tags(keep)?,
        Commands::SelectAssets {
            packages,
            architectures,
        } => select_assets(&packages, &architectures)?,
        Commands::AssetDigest { name } => asset_digest(&name)?,
        Commands::HandoffSelect {
            manifest,
            project,
            handoff: handoff_path,
            version,
        } => {
            let manifest = Manifest::load(&manifest)?;
            let mut releases: Vec<handoff::GithubRelease> = read_stdin_json()?;
            if releases.len() != 1 {
                return Err(
                    "AR175 signed channel handoff requires exactly one release response".into(),
                );
            }
            let release = releases.pop().unwrap();
            for row in handoff::select(&manifest, &project, &handoff_path, &version, &release)? {
                println!("{}\t{}\t{}\t{}\t{}", row.0, row.1, row.2, row.3, row.4);
            }
        }
        Commands::Render {
            manifest,
            project,
            pool_dir,
            output_dir,
            publication_epoch,
            component,
        } => {
            let manifest = Manifest::load(&manifest)?;
            if let Some(project) = project.as_deref() {
                manifest.project(project)?;
            }
            let component = manifest.component(component.as_deref())?;
            archive::render(
                &manifest,
                &pool_dir,
                &output_dir,
                &component,
                publication_epoch,
            )?;
            println!(
                "{}: rendered suite {}, component {}",
                manifest.domain.host, manifest.release.suite, component
            );
        }
        Commands::ReleaseTime {
            manifest,
            release,
            publication_epoch,
            now_epoch,
            max_age_seconds,
        } => {
            let manifest = Manifest::load(&manifest)?;
            release_time::validate(
                &manifest,
                &release,
                publication_epoch,
                now_epoch,
                max_age_seconds,
            )?;
        }
        Commands::Plan {
            manifest,
            project,
            archive_dir,
            publication_epoch,
            format,
        } => {
            let manifest = Manifest::load(&manifest)?;
            let plan = archive::plan(
                &manifest,
                &archive_dir,
                project.as_deref(),
                publication_epoch,
            )?;
            if format == OutputFormat::Json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&plan)
                        .map_err(|error| format!("AR140 cannot encode plan: {error}"))?
                );
            } else {
                print_plan(&plan);
            }
        }
        Commands::SnapshotPrepare {
            manifest,
            baseline,
            project,
            incoming_pool,
            output_pool,
        } => snapshot::prepare(
            &manifest,
            project.as_deref(),
            incoming_pool.as_deref(),
            &output_pool,
            &baseline,
        )?,
        Commands::SnapshotGuard {
            manifest,
            baseline,
            plan,
        } => {
            for entry in snapshot::guard(&manifest, &baseline, &plan)?
                .into_iter()
                .filter(|entry| !entry.skip)
            {
                println!(
                    "{}\t{}\t{}\t{}\t{}",
                    entry.phase, entry.local, entry.key, entry.content_type, entry.size
                );
            }
        }
        Commands::SnapshotCommitGuard { manifest, baseline } => {
            println!(
                "{}",
                snapshot::commit_guard(&manifest, &baseline)?
                    .unwrap_or_else(|| "ABSENT".to_string())
            );
        }
        Commands::VerifyCandidate {
            manifest,
            archive_dir,
            publication_epoch,
        } => snapshot::verify_candidate(&manifest, &archive_dir, publication_epoch)?,
        Commands::VerifyPublication {
            manifest,
            archive_dir,
            publication_epoch,
            project,
            base_url,
            local_only,
        } => {
            if local_only {
                snapshot::verify_candidate(&manifest, &archive_dir, publication_epoch)?;
                println!("signed domain candidate verified; no network writes");
            } else {
                snapshot::verify_publication(
                    &manifest,
                    &archive_dir,
                    publication_epoch,
                    project.as_deref(),
                    base_url.as_deref(),
                )?;
            }
        }
    }
    Ok(())
}

fn read_stdin_json<T: for<'de> Deserialize<'de>>() -> Result<T> {
    let mut input = String::new();
    io::stdin()
        .take(64 * 1024 * 1024)
        .read_to_string(&mut input)
        .map_err(|error| format!("AR170 cannot read input: {error}"))?;
    serde_json::from_str(&input).map_err(|error| format!("AR170 cannot parse input: {error}"))
}

fn select_tags(keep: usize) -> Result<()> {
    if keep == 0 {
        return Err("AR170 --keep must be at least 1".into());
    }
    let releases: Vec<ReleaseListing> = read_stdin_json()?;
    let mut stable = releases
        .into_iter()
        .filter(|release| !release.is_draft && !release.is_prerelease)
        .map(|release| {
            if release.tag_name.is_empty()
                || release.tag_name.contains('/')
                || release.tag_name.starts_with('-')
            {
                return Err(format!("AR170 unsafe tag name {:?}", release.tag_name));
            }
            let published = release.published_at.ok_or_else(|| {
                format!(
                    "AR170 stable release {:?} has no publication date",
                    release.tag_name
                )
            })?;
            if published.is_empty() {
                return Err(format!(
                    "AR170 stable release {:?} has no publication date",
                    release.tag_name
                ));
            }
            Ok((published, release.tag_name))
        })
        .collect::<Result<Vec<_>>>()?;
    if stable.is_empty() {
        return Err("AR170 the project has no stable release".into());
    }
    stable.sort_by(|left, right| right.0.cmp(&left.0).then(left.1.cmp(&right.1)));
    for (_, tag) in stable.into_iter().take(keep) {
        println!("{tag}");
    }
    Ok(())
}

fn select_assets(packages: &[String], architectures: &[String]) -> Result<()> {
    if packages.is_empty() || architectures.is_empty() {
        return Err("AR170 packages and architectures must not be empty".into());
    }
    static ASSET: OnceLock<Regex> = OnceLock::new();
    let pattern = ASSET.get_or_init(|| {
        Regex::new(
            r"^(?P<package>[a-z0-9][a-z0-9+.-]+)_(?P<version>[0-9][A-Za-z0-9.+~:-]*)_(?P<arch>[a-z0-9][a-z0-9-]*)\.deb$",
        )
        .expect("static regex")
    });
    let packages = packages.iter().collect::<BTreeSet<_>>();
    let architectures = architectures.iter().collect::<BTreeSet<_>>();
    let releases: Vec<AssetRelease> = read_stdin_json()?;
    let mut chosen = Vec::new();
    let mut identities = BTreeMap::new();
    for release in releases {
        if release.tag_name.is_empty() {
            return Err("AR170 a release carries no tag name".into());
        }
        for asset in release.assets {
            if !asset.name.ends_with(".deb") {
                continue;
            }
            let captures = pattern.captures(&asset.name).ok_or_else(|| {
                format!(
                    "AR170 {}: asset {:?} is not a canonical Debian name",
                    release.tag_name, asset.name
                )
            })?;
            let package = captures.name("package").unwrap().as_str();
            let version = captures.name("version").unwrap().as_str();
            let arch = captures.name("arch").unwrap().as_str();
            if !packages.contains(&package.to_string()) {
                continue;
            }
            if arch != "all" && !architectures.contains(&arch.to_string()) {
                continue;
            }
            let identity = (package.to_string(), version.to_string(), arch.to_string());
            if let Some(previous) = identities.insert(identity.clone(), release.tag_name.clone()) {
                return Err(format!(
                    "AR170 {} appears in {} and {previous}",
                    asset.name, release.tag_name
                ));
            }
            chosen.push((
                release.tag_name.clone(),
                asset.name,
                identity.0,
                identity.1,
                identity.2,
            ));
        }
    }
    if chosen.is_empty() {
        return Err("AR170 no stable release carries a declared .deb".into());
    }
    let present = chosen
        .iter()
        .map(|row| row.2.as_str())
        .collect::<BTreeSet<_>>();
    let missing = packages
        .iter()
        .filter(|package| !present.contains(package.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return Err(format!(
            "AR170 required packages are absent: {}",
            missing.into_iter().cloned().collect::<Vec<_>>().join(", ")
        ));
    }
    for row in chosen {
        println!("{}\t{}\t{}\t{}\t{}", row.0, row.1, row.2, row.3, row.4);
    }
    Ok(())
}

fn asset_digest(name: &str) -> Result<()> {
    let payload: Value = read_stdin_json()?;
    let assets = payload
        .get("assets")
        .and_then(Value::as_array)
        .ok_or_else(|| "AR180 release response carries no assets array".to_string())?;
    let matches = assets
        .iter()
        .filter(|asset| asset.get("name").and_then(Value::as_str) == Some(name))
        .collect::<Vec<_>>();
    if matches.len() != 1 {
        return Err(format!(
            "AR180 release response names {name:?} {} times",
            matches.len()
        ));
    }
    let digest = matches[0]
        .get("digest")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if digest.is_empty() {
        println!();
    } else if let Some(value) = digest.strip_prefix("sha256:") {
        println!("{value}");
    } else {
        return Err(format!("AR180 unsupported asset digest: {digest:?}"));
    }
    Ok(())
}

fn print_plan(plan: &archive::PublicationPlan) {
    for entry in &plan.entries {
        println!(
            "{}\t{}\t{}\t{}\t{}",
            entry.phase, entry.local, entry.key, entry.content_type, entry.size
        );
    }
}
