use crate::{archive, handoff, manifest::Manifest, snapshot};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Cursor,
    path::Path,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};
use tempfile::TempDir;

#[test]
fn signed_candidate_round_trip() {
    let temporary = TempDir::new().unwrap();
    let home = temporary.path().join("gnupg");
    fs::create_dir(&home).unwrap();
    set_mode(&home, 0o700);
    run(
        "gpg",
        [
            "--batch",
            "--homedir",
            home.to_str().unwrap(),
            "--passphrase",
            "",
            "--quick-gen-key",
            "APT archive test <archive@example.invalid>",
            "ed25519",
            "cert",
            "0",
        ],
    );
    let (primary, _) = fingerprints(&home);
    run(
        "gpg",
        [
            "--batch",
            "--homedir",
            home.to_str().unwrap(),
            "--passphrase",
            "",
            "--quick-add-key",
            &primary,
            "ed25519",
            "sign",
            "0",
        ],
    );
    let (primary, subkey) = fingerprints(&home);
    let manifest_path = temporary.path().join("manifest.toml");
    fs::write(&manifest_path, test_manifest(&primary, &subkey)).unwrap();
    let manifest = Manifest::load(&manifest_path).unwrap();
    let pool = temporary.path().join("pool");
    fs::create_dir(&pool).unwrap();
    make_deb(&pool.join("demo_1.0.0_amd64.deb"), "demo", "1.0.0", "amd64");
    make_deb(&pool.join("demo_1.0.0_arm64.deb"), "demo", "1.0.0", "arm64");
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let candidate = temporary.path().join("candidate");
    archive::render(&manifest, &pool, &candidate, "main", epoch).unwrap();
    sign_candidate(&home, &candidate, &manifest, epoch, &subkey);
    snapshot::verify_candidate(&manifest_path, &candidate, epoch).unwrap();
    let plan = archive::plan(&manifest, &candidate, Some("demo"), epoch).unwrap();
    assert!(plan.entries.iter().any(|entry| entry.phase == "pool"));
    assert_eq!(
        plan.entries.last().map(|entry| entry.key.as_str()),
        Some("dists/rolling/InRelease")
    );

    let package = candidate.join("pool/main/d/demo/demo_1.0.0_amd64.deb");
    let mut bytes = fs::read(&package).unwrap();
    bytes[80] ^= 1;
    fs::write(&package, bytes).unwrap();
    assert!(snapshot::verify_candidate(&manifest_path, &candidate, epoch).is_err());
}

#[test]
fn signed_handoff_selects_exact_public_packages() {
    let temporary = TempDir::new().unwrap();
    let manifest_path = temporary.path().join("manifest.toml");
    fs::write(&manifest_path, test_manifest("TBD", "TBD")).unwrap();
    let manifest = Manifest::load(&manifest_path).unwrap();
    let package_amd64 = identity("ami-rust_0.3.0_amd64.deb", b"amd64");
    let package_arm64 = identity("ami-rust_0.3.0_arm64.deb", b"arm64");
    let input = identity("rust-std-0.3.0-linux-x86_64.tar.xz", b"input");
    let archive = identity("ami-rust-0.3.0-linux-x86_64.tar.xz", b"archive");
    let formula = identity("ami-rust.rb", b"formula");
    let handoff_path = temporary.path().join("channel-handoff.json");
    fs::write(
        &handoff_path,
        serde_json::to_vec(&json!({
            "schema":"ami-rust-rp3-channel-handoff-v1",
            "status":"EXACT_RELEASE_ASSET_IDENTITIES_FOR_PACKAGE_CHANNELS",
            "version":"0.3.0",
            "release_tag":"v0.3.0",
            "qualification":{"run_id":1,"run_attempt":1},
            "assets":[package_amd64,package_arm64,input,archive,formula],
            "direct":{"archives":[archive]},
            "rustup":{"manifest":"channel-rust-0.3.0.toml","checksum":"channel-rust-0.3.0.toml.sha256","component_count":9},
            "apt":{"repository":"metaneutrons/apt-archive","packages":[package_amd64,package_arm64],"inputs":[input],"rebuild_sdk":false},
            "homebrew":{"repository":"metaneutrons/homebrew-tap","formula":formula,"input":archive,"archive":archive,"rebuild_sdk":false},
            "claim":"exact bytes"
        }))
        .unwrap(),
    )
    .unwrap();
    let release = handoff::GithubRelease {
        tag_name: "v0.3.0".into(),
        assets: vec![
            github_asset("ami-rust_0.3.0_amd64.deb", b"amd64"),
            github_asset("ami-rust_0.3.0_arm64.deb", b"arm64"),
        ],
    };
    let selected =
        handoff::select(&manifest, "ami-rust", &handoff_path, "0.3.0", &release).unwrap();
    assert_eq!(selected.len(), 2);
}

fn make_deb(path: &Path, package: &str, version: &str, architecture: &str) {
    let control = format!(
        "Package: {package}\nVersion: {version}\nArchitecture: {architecture}\nDescription: test\n"
    );
    let mut tar_bytes = Vec::new();
    {
        let mut builder = tar::Builder::new(&mut tar_bytes);
        let mut header = tar::Header::new_gnu();
        header.set_size(control.len() as u64);
        header.set_mode(0o644);
        header.set_mtime(0);
        header.set_cksum();
        builder
            .append_data(&mut header, "./control", control.as_bytes())
            .unwrap();
        builder.finish().unwrap();
    }
    let control_zstd = zstd::stream::encode_all(Cursor::new(tar_bytes), 19).unwrap();
    let data_tar = {
        let mut bytes = Vec::new();
        tar::Builder::new(&mut bytes).finish().unwrap();
        bytes
    };
    let file = File::create(path).unwrap();
    let mut ar = ar::Builder::new(file);
    ar.append(
        &ar::Header::new(b"debian-binary".to_vec(), 4),
        Cursor::new(b"2.0\n"),
    )
    .unwrap();
    ar.append(
        &ar::Header::new(
            b"control.tar.zst".to_vec(),
            u64::try_from(control_zstd.len()).unwrap(),
        ),
        Cursor::new(control_zstd),
    )
    .unwrap();
    ar.append(
        &ar::Header::new(b"data.tar".to_vec(), u64::try_from(data_tar.len()).unwrap()),
        Cursor::new(data_tar),
    )
    .unwrap();
}

fn sign_candidate(home: &Path, candidate: &Path, manifest: &Manifest, epoch: u64, subkey: &str) {
    let release = candidate
        .join("dists")
        .join(&manifest.release.suite)
        .join("Release");
    let common = [
        "--batch",
        "--homedir",
        home.to_str().unwrap(),
        "--yes",
        "--pinentry-mode",
        "loopback",
        "--passphrase",
        "",
        "--faked-system-time",
        &format!("{epoch}!"),
        "--local-user",
        &format!("{subkey}!"),
    ];
    let release_gpg = release.with_file_name("Release.gpg");
    let inrelease = release.with_file_name("InRelease");
    run_with_tail(
        "gpg",
        &common,
        &[
            "--armor",
            "--detach-sign",
            "--output",
            release_gpg.to_str().unwrap(),
            release.to_str().unwrap(),
        ],
    );
    run_with_tail(
        "gpg",
        &common,
        &[
            "--armor",
            "--clearsign",
            "--output",
            inrelease.to_str().unwrap(),
            release.to_str().unwrap(),
        ],
    );
    let armored = candidate.join(format!("{}.asc", manifest.domain.keyring_package));
    let binary = candidate.join(format!("{}.pgp", manifest.domain.keyring_package));
    let output = Command::new("gpg")
        .args([
            "--batch",
            "--homedir",
            home.to_str().unwrap(),
            "--armor",
            "--no-emit-version",
            "--no-comments",
            "--export",
            &format!("{subkey}!"),
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    fs::write(armored, output.stdout).unwrap();
    let output = Command::new("gpg")
        .args([
            "--batch",
            "--homedir",
            home.to_str().unwrap(),
            "--no-emit-version",
            "--export",
            &format!("{subkey}!"),
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    fs::write(binary, output.stdout).unwrap();
}

fn fingerprints(home: &Path) -> (String, String) {
    let output = Command::new("gpg")
        .args([
            "--batch",
            "--homedir",
            home.to_str().unwrap(),
            "--with-colons",
            "--list-keys",
            "--fingerprint",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    let mut primary = None;
    let mut subkey = None;
    let mut kind = None;
    for line in text.lines() {
        let fields = line.split(':').collect::<Vec<_>>();
        match fields[0] {
            "pub" => kind = Some("pub"),
            "sub" => kind = Some("sub"),
            "fpr" => match kind.take() {
                Some("pub") => primary = Some(fields[9].to_string()),
                Some("sub") => subkey = Some(fields[9].to_string()),
                _ => {}
            },
            _ => {}
        }
    }
    (primary.unwrap(), subkey.unwrap_or_default())
}

fn test_manifest(primary: &str, subkey: &str) -> String {
    format!(
        r#"[domain]
layout = "shared-root-v1"
host = "deb.example.invalid"
base_url = "https://deb.example.invalid"
origin = "example"
keyring_package = "example-archive-keyring"
keyring_file = "/usr/share/keyrings/example-archive-keyring.pgp"

[signing]
primary_fingerprint = "{primary}"
signing_subkey = "{subkey}"

[publication]
r2_bucket = "example-bucket"
r2_account_id = "0123456789abcdef0123456789abcdef"

[release]
suite = "rolling"
codename = "rolling"
components = ["main"]
architectures = ["amd64", "arm64"]
acquire_by_hash = true
valid_until_days = 180

[[projects]]
name = "demo"
source_repo = "example/demo"
packages = ["demo"]
keep_versions = 5

[[projects]]
name = "ami-rust"
source_repo = "metaneutrons/ami-rust"
packages = ["ami-rust"]
keep_versions = 5
"#
    )
}

fn identity(name: &str, bytes: &[u8]) -> serde_json::Value {
    json!({"name":name,"bytes":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))})
}

fn github_asset(name: &str, bytes: &[u8]) -> handoff::GithubAsset {
    handoff::GithubAsset {
        name: name.into(),
        size: bytes.len() as u64,
        digest: Some(format!("sha256:{:x}", Sha256::digest(bytes))),
    }
}

fn run<const N: usize>(program: &str, arguments: [&str; N]) {
    let status = Command::new(program).args(arguments).status().unwrap();
    assert!(status.success());
}

fn run_with_tail(program: &str, common: &[&str], tail: &[&str]) {
    let status = Command::new(program)
        .args(common)
        .args(tail)
        .status()
        .unwrap();
    assert!(status.success());
}

fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}
