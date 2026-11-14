//! `changemylocation-cli`, the engine from the command line
//!
//!     changemylocation-cli list                     one phone per line, udid<TAB>name<TAB>usb|wifi<TAB>devmode
//!                                                   devmode is on, off or unknown
//!     changemylocation-cli set <udid> <lat> <lon>   hand the phone a location to hold
//!     changemylocation-cli clear <udid>             back to the real location
//!     changemylocation-cli reveal-developer-mode <udid>   show the developer mode switch in the phone's settings
//!     changemylocation-cli route <udid> <speed> <lat,lon> <lat,lon>...   move along waypoints at speed m/s

use std::process::ExitCode;

use changemylocation_core::{
    Link, Result, clear_location, phones, play_route, reveal_developer_mode, set_location, within_a_minute,
};

const USAGE: &str = "usage: changemylocation-cli list | set <udid> <lat> <lon> | clear <udid> | reveal-developer-mode <udid> | route <udid> <speed> <lat,lon>...";

#[tokio::main]
async fn main() -> ExitCode {
    // RUST_LOG=debug shows what the iphone and apple's servers answered at each step
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["list"] => list().await,
        ["set", udid, lat, lon] => match (lat.parse(), lon.parse()) {
            (Ok(lat), Ok(lon)) => within_a_minute(set_location(udid, lat, lon)).await,
            _ => return usage(),
        },
        ["clear", udid] => within_a_minute(clear_location(udid)).await,
        ["reveal-developer-mode", udid] => within_a_minute(reveal_developer_mode(udid)).await,
        ["route", udid, speed, points @ ..] if points.len() >= 2 => {
            let parsed: Option<Vec<(f64, f64)>> = points
                .iter()
                .map(|p| {
                    let (lat, lon) = p.split_once(',')?;
                    Some((lat.parse().ok()?, lon.parse().ok()?))
                })
                .collect();
            match (speed.parse(), parsed) {
                (Ok(speed), Some(points)) => within_a_minute(play_route(udid, &points, speed)).await,
                _ => return usage(),
            }
        }
        _ => return usage(),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

async fn list() -> Result<()> {
    for p in phones().await? {
        let link = if p.link == Link::Usb { "usb" } else { "wifi" };
        let devmode = match p.developer_mode {
            Some(true) => "on",
            Some(false) => "off",
            None => "unknown",
        };
        println!("{}\t{}\t{link}\t{devmode}", p.udid, p.name);
    }
    Ok(())
}

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}
