//! `changemylocation-cli`: the engine from the command line.
//!
//!     changemylocation-cli list                     one phone per line: udid<TAB>name<TAB>usb|wifi
//!     changemylocation-cli set <udid> <lat> <lon>   hand the phone a location to hold
//!     changemylocation-cli clear <udid>             back to the real location

use std::process::ExitCode;

use std::{future::Future, time::Duration};

use changemylocation_core::{Error, Link, Result, clear_location, phones, set_location};

const USAGE: &str = "usage: changemylocation-cli list | set <udid> <lat> <lon> | clear <udid>";

#[tokio::main]
async fn main() -> ExitCode {
    // RUST_LOG=debug shows what the iPhone and Apple's servers answered at each step.
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["list"] => phones().await.map(|list| {
            for p in list {
                let link = if p.link == Link::Usb { "usb" } else { "wifi" };
                println!("{}\t{}\t{link}", p.udid, p.name);
            }
        }),
        ["set", udid, lat, lon] => match (lat.parse(), lon.parse()) {
            (Ok(lat), Ok(lon)) => within_a_minute(set_location(udid, lat, lon)).await,
            _ => {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            }
        },
        ["clear", udid] => within_a_minute(clear_location(udid)).await,
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// A sleeping phone can leave a connection hanging; give up after a minute so the app never waits forever.
async fn within_a_minute(action: impl Future<Output = Result<()>>) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(60), action)
        .await
        .unwrap_or_else(|_| Err(Error::Other("The iPhone stopped answering. Unlock it, or plug it in.".into())))
}
