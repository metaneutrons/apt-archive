use crate::manifest::Result;
use std::{
    ffi::OsStr,
    process::{Command, Output},
};

pub fn run<I, S>(program: &str, arguments: I) -> Result<Output>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new(program)
        .args(arguments)
        .output()
        .map_err(|error| format!("AR190 cannot execute {program}: {error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "AR190 {program} rejected the operation ({}): {}",
            output.status,
            stderr.trim()
        ));
    }
    Ok(output)
}
