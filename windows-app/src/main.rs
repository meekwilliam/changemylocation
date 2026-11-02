// No console window behind the app in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! changemylocation for Windows: the map page in web/ plus these commands, which call the same engine as the Mac
//! app (core/). Each phone's last spot is remembered in %APPDATA%\changemylocation\state.json, the same file the
//! older Python version used, and every Set and Reset is logged next to it.

use std::{fs, io::Write, path::PathBuf, time::Duration};

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use changemylocation_core::{self as engine, Link, http::HttpRequest};
use serde::Serialize;
use serde_json::{Map, Value, json};

const USER_AGENT: &str =
    concat!("changemylocation/", env!("CARGO_PKG_VERSION"), " (+https://github.com/meekwilliam/changemylocation)");
const LATEST_RELEASE: &str = "https://api.github.com/repos/meekwilliam/changemylocation/releases/latest";
const LATEST_DOWNLOAD: &str = "https://github.com/meekwilliam/changemylocation/releases/latest/download/";
/// The project's update signing key, the same one the Mac app's updater trusts. Releases sign
/// changemylocation.exe with its private half (changemylocation.exe.sig).
const UPDATE_KEY: &str = "Hps3V99anq2uSo3nTXfp7jnGl9MjrfoIMb7nK9LyILc=";

#[derive(Serialize)]
struct Reply {
    ok: bool,
    message: String,
}

#[derive(Serialize)]
struct Update {
    version: String,
    url: String,
}

#[tauri::command]
async fn phones() -> Value {
    match engine::phones().await {
        Ok(found) => {
            let last = load_state();
            json!(
                found
                    .iter()
                    .map(|p| json!({
                        "udid": p.udid,
                        "name": p.name,
                        "connection": if p.link == Link::Usb { "USB" } else { "Network" },
                        "developerMode": p.developer_mode,
                        "last": last.get(&p.udid),
                    }))
                    .collect::<Vec<_>>()
            )
        }
        Err(e) => {
            log(&format!("listing phones failed: {e}"));
            json!({ "error": "Can't see any iPhones. Install Apple Devices from the Microsoft Store, then plug in your iPhone." })
        }
    }
}

#[tauri::command]
async fn set(udid: String, lat: f64, lon: f64, name: Option<String>) -> Reply {
    log(&format!("[{}] Set Location pressed ({lat:.5}, {lon:.5})", short(&udid)));
    match within_a_minute(engine::set_location(&udid, lat, lon)).await {
        Ok(()) => {
            let mut state = load_state();
            state.insert(udid, json!({ "lat": lat, "lon": lon, "name": name.unwrap_or_default() }));
            save_state(&state);
            let message =
                format!("Location set to {lat:.5}, {lon:.5}. The iPhone holds it on its own until Reset or a restart.");
            Reply { ok: true, message }
        }
        Err(e) => {
            log(&format!("[{}] set failed: {e}", short(&udid)));
            Reply { ok: false, message: e }
        }
    }
}

#[tauri::command]
async fn clear(udid: String) -> Reply {
    log(&format!("[{}] Reset pressed", short(&udid)));
    match within_a_minute(engine::clear_location(&udid)).await {
        Ok(()) => {
            let mut state = load_state();
            state.remove(&udid);
            save_state(&state);
            Reply { ok: true, message: "Restored the real location.".into() }
        }
        Err(e) => {
            log(&format!("[{}] reset failed: {e}", short(&udid)));
            Reply { ok: false, message: format!("Couldn't reach the iPhone to reset it: {e}") }
        }
    }
}

#[tauri::command]
async fn reveal_developer_mode(udid: String) {
    match within_a_minute(engine::reveal_developer_mode(&udid)).await {
        Ok(()) => log(&format!("[{}] revealed the Developer Mode switch", short(&udid))),
        Err(e) => log(&format!("[{}] couldn't reveal the Developer Mode switch: {e}", short(&udid))),
    }
}

/// Place search, through OpenStreetMap's Nominatim.
#[tauri::command]
async fn search(query: String) -> Value {
    let url = format!("https://nominatim.openstreetmap.org/search?q={}&format=jsonv2&limit=6", encode(&query));
    let results = get_json(&url).await.unwrap_or_default();
    let places: Vec<Value> = results
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let display = r["display_name"].as_str()?;
            let name = r["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(display.split(',').next()?);
            Some(json!({
                "name": name,
                "subtitle": display,
                "lat": r["lat"].as_str()?.parse::<f64>().ok()?,
                "lon": r["lon"].as_str()?.parse::<f64>().ok()?,
            }))
        })
        .collect();
    json!(places)
}

/// The name of the place at a spot clicked on the map.
#[tauri::command]
async fn describe(lat: f64, lon: f64) -> Value {
    let url = format!("https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lon}&format=jsonv2&zoom=18");
    let r = get_json(&url).await.unwrap_or_default();
    json!({
        "name": r["name"].as_str().filter(|n| !n.is_empty()).unwrap_or("Dropped pin"),
        "subtitle": r["display_name"].as_str().unwrap_or(""),
    })
}

/// A newer release on GitHub, if there is one.
#[tauri::command]
async fn update() -> Option<Update> {
    let release = get_json(LATEST_RELEASE).await?;
    let latest = release["tag_name"].as_str()?.trim_start_matches('v').to_string();
    let url = release["html_url"].as_str()?.to_string();
    newer(&latest, env!("CARGO_PKG_VERSION")).then_some(Update { version: latest, url })
}

/// Downloads the latest changemylocation.exe, checks it's signed with the project's key, swaps it in for this
/// one and restarts. Windows lets a running exe be renamed, so the old one moves aside and is deleted next launch.
#[tauri::command]
async fn install_update(app: tauri::AppHandle) -> Result<(), String> {
    if !cfg!(windows) {
        return Err("Updates install themselves only in the Windows app.".into());
    }
    let exe = download(&format!("{LATEST_DOWNLOAD}changemylocation.exe")).await?;
    let signature = download(&format!("{LATEST_DOWNLOAD}changemylocation.exe.sig")).await?;
    verify(&exe, &signature)?;
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let fresh = current.with_extension("new");
    fs::write(&fresh, &exe).map_err(|e| format!("Couldn't save the update: {e}"))?;
    let _ = fs::remove_file(current.with_extension("old"));
    fs::rename(&current, current.with_extension("old")).map_err(|e| format!("Couldn't replace the app: {e}"))?;
    fs::rename(&fresh, &current).map_err(|e| format!("Couldn't replace the app: {e}"))?;
    log("installed an update; restarting");
    std::process::Command::new(&current).spawn().map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}

/// Opens a changemylocation page on GitHub in the browser.
#[tauri::command]
fn open_page(url: String) {
    if !url.starts_with("https://github.com/meekwilliam/changemylocation/") {
        return;
    }
    #[cfg(windows)]
    let _ = std::process::Command::new("explorer").arg(&url).spawn();
    #[cfg(not(windows))]
    let _ = std::process::Command::new("open").arg(&url).spawn();
}

fn verify(data: &[u8], signature: &[u8]) -> Result<(), String> {
    let refuse = || "The update isn't signed by changemylocation, so it wasn't installed.".to_string();
    let key: [u8; 32] = BASE64.decode(UPDATE_KEY).ok().and_then(|k| k.try_into().ok()).ok_or_else(refuse)?;
    let key = ed25519_dalek::VerifyingKey::from_bytes(&key).map_err(|_| refuse())?;
    let signature = BASE64.decode(String::from_utf8_lossy(signature).trim()).map_err(|_| refuse())?;
    let signature = ed25519_dalek::Signature::from_slice(&signature).map_err(|_| refuse())?;
    key.verify_strict(data, &signature).map_err(|_| refuse())
}

async fn get_json(url: &str) -> Option<Value> {
    let response = HttpRequest::get(url).header("User-Agent", USER_AGENT).send().await.ok()?;
    if response.status != 200 {
        return None;
    }
    response.json().ok()
}

async fn download(url: &str) -> Result<Vec<u8>, String> {
    let response = HttpRequest::get(url)
        .header("User-Agent", USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("Couldn't download the update: {e}"))?;
    if response.status != 200 {
        return Err(format!("Couldn't download the update (HTTP {}).", response.status));
    }
    Ok(response.body)
}

/// A slow or sleeping phone can leave a connection hanging; give up after a minute.
async fn within_a_minute(action: impl Future<Output = engine::Result<()>>) -> Result<(), String> {
    match tokio::time::timeout(Duration::from_secs(60), action).await {
        Ok(result) => result.map_err(|e| e.to_string()),
        Err(_) => Err("The iPhone stopped answering. Unlock it, or plug it in.".into()),
    }
}

/// Compares version numbers like 1.10 and 1.9 by their parts.
fn newer(a: &str, b: &str) -> bool {
    let parts = |v: &str| v.split('.').map(|p| p.parse::<u32>().unwrap_or(0)).collect::<Vec<_>>();
    let (mut x, mut y) = (parts(a), parts(b));
    let n = x.len().max(y.len());
    x.resize(n, 0);
    y.resize(n, 0);
    x > y
}

/// Percent-encodes a search query for a URL.
fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn short(udid: &str) -> &str {
    &udid[udid.len().saturating_sub(4)..]
}

fn state_path() -> PathBuf {
    engine::app_dir().join("state.json")
}

fn load_state() -> Map<String, Value> {
    fs::read(state_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_state(state: &Map<String, Value>) {
    let _ = fs::create_dir_all(engine::app_dir());
    let _ = fs::write(state_path(), serde_json::to_vec_pretty(state).unwrap_or_default());
}

fn log(line: &str) {
    let seconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let _ = fs::create_dir_all(engine::app_dir());
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(engine::app_dir().join("changemylocation.log")) {
        let _ = writeln!(f, "{seconds} {line}");
    }
}

fn main() {
    // An update leaves the previous exe beside this one; it isn't running any more.
    if let Ok(exe) = std::env::current_exe() {
        let _ = fs::remove_file(exe.with_extension("old"));
    }
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            phones,
            set,
            clear,
            reveal_developer_mode,
            search,
            describe,
            update,
            install_update,
            open_page
        ])
        .run(tauri::generate_context!())
        .expect("couldn't start changemylocation");
}
