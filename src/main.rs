mod archive;
mod command;
mod deb;
mod handoff;
mod manifest;
mod process;
mod release_time;
mod snapshot;

#[cfg(test)]
mod tests;

fn main() {
    if let Err(error) = command::run() {
        eprintln!("::error::{error}");
        std::process::exit(1);
    }
}
