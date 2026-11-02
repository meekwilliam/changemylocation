//! changemylocation's engine. It talks to iPhones directly (no Xcode, no Python) and hands them a location to hold.
//!
//! Set Location calls the phone's CoreDevice location service over Apple's developer tunnel. The phone's own
//! `dtlocationd` then runs the simulation with nothing connected, until Reset or a restart. The tunnel runs on a
//! userspace TCP stack, so nothing needs admin rights; the iPhone is reached through Apple's device service
//! (`usbmuxd`), which macOS has built in and Windows gets from the Apple Devices app.

use std::{borrow::Cow, fmt, path::PathBuf};

use idevice::{
    IdeviceError, IdeviceService, ReadWrite, RsdService,
    core_device::CoreDeviceServiceClient,
    core_device_proxy::CoreDeviceProxy,
    amfi::AmfiClient,
    lockdown::LockdownClient,
    mobile_image_mounter::ImageMounter,
    provider::{IdeviceProvider, RsdProvider},
    rsd::RsdHandshake,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};

const LABEL: &str = "changemylocation";

/// idevice's small HTTP client, for apps built on the engine (place search, update checks).
pub use idevice::http;
const FEATURE: &str = "com.apple.coredevice.feature.simulatelocation";
const SET: &str = "com.apple.coredevice.action.setsimulatedlocation";
const CLEAR: &str = "com.apple.coredevice.action.clearsimulatedlocation";

/// Apple's personalized developer disk image, the same files Xcode ships, mirrored on GitHub.
const DDI_URL: &str =
    "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized";
const DDI_FILES: [&str; 3] = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"];

#[derive(Debug)]
pub enum Error {
    /// No iPhone with that UDID is connected by cable or visible on Wi-Fi right now.
    NotFound(String),
    /// Something the iPhone or Apple's servers answered with.
    Device(IdeviceError),
    Other(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotFound(udid) => write!(f, "Can't reach the iPhone {udid}. Unlock it, or plug it in."),
            Error::Device(IdeviceError::DeviceLocked) => f.write_str(
                "Unlock the iPhone. After a restart, it has to be unlocked once to load its developer tools.",
            ),
            Error::Device(IdeviceError::DeveloperModeNotEnabled) => {
                f.write_str("Turn on Developer Mode on the iPhone: Settings › Privacy & Security › Developer Mode.")
            }
            Error::Device(IdeviceError::InvalidHostID) => f.write_str("This iPhone doesn't trust this computer yet. Plug it in, unlock it, and tap Trust."),
            Error::Device(IdeviceError::Timeout) => f.write_str("The iPhone stopped answering. Unlock it, or plug it in."),
            Error::Device(e) => write!(f, "{e}"),
            Error::Other(s) => f.write_str(s),
        }
    }
}

impl std::error::Error for Error {}

impl From<IdeviceError> for Error {
    fn from(e: IdeviceError) -> Self {
        Error::Device(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Other(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Link {
    Usb,
    WiFi,
}

#[derive(Debug, Clone)]
pub struct Phone {
    pub udid: String,
    pub name: String,
    pub link: Link,
    /// Whether Developer Mode is on, when the phone says.
    pub developer_mode: Option<bool>,
}

/// The iPhones Apple's device service sees, one entry each (by cable when both are available).
pub async fn phones() -> Result<Vec<Phone>> {
    let mut found: Vec<Phone> = Vec::new();
    for device in devices().await? {
        let link = match device.connection_type {
            Connection::Usb => Link::Usb,
            Connection::Network(_) => Link::WiFi,
            Connection::Unknown(_) => continue,
        };
        if let Some(phone) = found.iter_mut().find(|p| p.udid == device.udid) {
            if link == Link::Usb {
                phone.link = Link::Usb;
            }
            continue;
        }
        let provider = device.to_provider(UsbmuxdAddr::default(), LABEL);
        let name = device_name(&provider)
            .await
            .unwrap_or_else(|| format!("iPhone {}", &device.udid[device.udid.len().saturating_sub(4)..]));
        let developer_mode = developer_mode(&provider).await;
        found.push(Phone { udid: device.udid, name, link, developer_mode });
    }
    found.sort_by_key(|p| p.name.to_lowercase());
    Ok(found)
}

/// Hands the spot to the phone, which then holds it on its own until Reset or a restart.
pub async fn set_location(udid: &str, latitude: f64, longitude: f64) -> Result<()> {
    let provider = provider(udid).await?;
    let mut input = plist::Dictionary::new();
    input.insert("latitude".into(), plist::Value::Real(latitude));
    input.insert("longitude".into(), plist::Value::Real(longitude));
    invoke(&provider, SET, input).await
}

/// Makes the Developer Mode switch appear in the phone's Settings › Privacy & Security. iOS hides it until a
/// developer tool has connected, which on a Mac is normally Xcode.
pub async fn reveal_developer_mode(udid: &str) -> Result<()> {
    let provider = provider(udid).await?;
    let mut amfi = AmfiClient::connect(&provider).await?;
    Ok(amfi.reveal_developer_mode_option_in_ui().await?)
}

/// Back to the real location. The phone has to be reachable (cable or same Wi-Fi).
pub async fn clear_location(udid: &str) -> Result<()> {
    let provider = provider(udid).await?;
    invoke(&provider, CLEAR, plist::Dictionary::new()).await
}

async fn devices() -> Result<Vec<UsbmuxdDevice>> {
    let mut usbmuxd = UsbmuxdConnection::default().await?;
    Ok(usbmuxd.get_devices().await?)
}

/// A connection to the phone through Apple's device service, preferring the cable over Wi-Fi.
async fn provider(udid: &str) -> Result<impl IdeviceProvider> {
    let mut matching: Vec<UsbmuxdDevice> = devices().await?.into_iter().filter(|d| d.udid == udid).collect();
    matching.sort_by_key(|d| !matches!(d.connection_type, Connection::Usb));
    let device = matching.into_iter().next().ok_or_else(|| Error::NotFound(udid.to_string()))?;
    Ok(device.to_provider(UsbmuxdAddr::default(), LABEL))
}

/// Reads a lockdown value, starting a paired session if the phone won't answer without one.
async fn lockdown_value(provider: &dyn IdeviceProvider, key: &str) -> Result<plist::Value> {
    lockdown_value_in(provider, key, None).await
}

async fn lockdown_value_in(provider: &dyn IdeviceProvider, key: &str, domain: Option<&str>) -> Result<plist::Value> {
    let mut lockdown = LockdownClient::connect(provider).await?;
    match lockdown.get_value(Some(key), domain).await {
        Ok(v) => Ok(v),
        Err(_) => {
            lockdown.start_session(&provider.get_pairing_file().await?).await?;
            Ok(lockdown.get_value(Some(key), domain).await?)
        }
    }
}

async fn developer_mode(provider: &dyn IdeviceProvider) -> Option<bool> {
    lockdown_value_in(provider, "DeveloperModeStatus", Some("com.apple.security.mac.amfi")).await.ok()?.as_boolean()
}

async fn device_name(provider: &dyn IdeviceProvider) -> Option<String> {
    lockdown_value(provider, "DeviceName").await.ok()?.as_string().map(str::to_string)
}

fn has_developer_tools(mounted: &[plist::Value]) -> bool {
    // lookup_image("Personalized") answers NotFound even while the image is mounted, so read the mount list.
    mounted.iter().any(|image| {
        image.as_dictionary().and_then(|d| d.get("DiskImageType")).and_then(plist::Value::as_string)
            == Some("Personalized")
    })
}

async fn chip_id(provider: &dyn IdeviceProvider) -> Result<u64> {
    lockdown_value(provider, "UniqueChipID")
        .await?
        .as_unsigned_integer()
        .ok_or_else(|| Error::Other("The iPhone didn't report its chip ID.".into()))
}

/// Loads the developer tools on the phone if a restart unloaded them (devicectl does this silently on a Mac),
/// over the plain lockdown connection. Uploading the 15 MB image works there over USB; the tunnel's userspace
/// TCP stack times out on it, and over Wi-Fi the phone closes lockdown mid-upload, so that case falls back to
/// `load_developer_tools_tunneled`. Returns whether the tools are loaded.
async fn load_developer_tools(provider: &dyn IdeviceProvider) -> Result<bool> {
    let mut mounter = ImageMounter::connect(provider).await?;
    if has_developer_tools(&mounter.copy_devices().await?) {
        return Ok(true);
    }
    let [image, trust_cache, manifest] = developer_disk_image().await?;
    let chip_id = chip_id(provider).await?;
    match mounter.mount_personalized(provider, image, trust_cache, &manifest, None, chip_id).await {
        Ok(()) => {
            eprintln!("Loaded the developer tools on the iPhone.");
            Ok(true)
        }
        Err(IdeviceError::DeviceLocked) => Err(IdeviceError::DeviceLocked.into()),
        Err(_) => Ok(false),
    }
}

/// The same through the developer tunnel, for when lockdown couldn't (Wi-Fi).
async fn load_developer_tools_tunneled(
    provider: &dyn IdeviceProvider,
    adapter: &mut impl RsdProvider,
    handshake: &mut RsdHandshake,
) -> Result<()> {
    let mut mounter = ImageMounter::connect_rsd(adapter, handshake).await?;
    if has_developer_tools(&mounter.copy_devices().await?) {
        return Ok(());
    }
    let [image, trust_cache, manifest] = developer_disk_image().await?;
    let chip_id = chip_id(provider).await?;
    mounter.mount_personalized_rsd(adapter, handshake, image, trust_cache, &manifest, None, chip_id).await?;
    eprintln!("Loaded the developer tools on the iPhone.");
    Ok(())
}

/// Apple's developer disk image files, downloaded once and cached.
async fn developer_disk_image() -> Result<[Vec<u8>; 3]> {
    let dir = cache_dir().join("DeveloperDiskImage");
    tokio::fs::create_dir_all(&dir).await?;
    let mut files: Vec<Vec<u8>> = Vec::new();
    for name in DDI_FILES {
        let path = dir.join(name);
        let bytes = match tokio::fs::read(&path).await {
            Ok(bytes) if !bytes.is_empty() => bytes,
            _ => {
                let response = idevice::http::get(format!("{DDI_URL}/{name}")).await?;
                if response.status != 200 {
                    return Err(Error::Other(format!(
                        "Couldn't download Apple's developer files ({name}: HTTP {}). Check the internet connection.",
                        response.status
                    )));
                }
                tokio::fs::write(&path, &response.body).await?;
                response.body
            }
        };
        files.push(bytes);
    }
    Ok(files.try_into().expect("three files"))
}

/// Where changemylocation keeps its files: %APPDATA%\changemylocation on Windows,
/// ~/Library/Application Support/changemylocation on a Mac.
pub fn app_dir() -> PathBuf {
    cache_dir()
}

fn cache_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(std::env::temp_dir);
    let dir = base.join("changemylocation");
    // Downloaded before the rename from imsomeeked; reuse it instead of fetching it again.
    let old = base.join("imsomeeked");
    if !dir.exists() && old.is_dir() {
        let _ = std::fs::rename(&old, &dir);
    }
    dir
}

/// Opens Apple's developer tunnel to the phone, makes sure the developer tools are loaded, and calls one location
/// action on its CoreDevice location service.
async fn invoke(provider: &dyn IdeviceProvider, action: &str, input: plist::Dictionary) -> Result<()> {
    let loaded = load_developer_tools(provider).await?;
    let proxy = CoreDeviceProxy::connect(provider).await?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let stream = adapter.connect(rsd_port).await?;
    let mut handshake = RsdHandshake::new(stream).await?;
    if !loaded {
        load_developer_tools_tunneled(provider, &mut adapter, &mut handshake).await?;
    }
    let mut service = SimulateLocation::connect_rsd(&mut adapter, &mut handshake).await?;
    service.0.invoke_with_plist_action(FEATURE, input, action).await?;
    Ok(())
}

/// The phone's CoreDevice location service. idevice's own client only lists scenarios, so this one sets and clears.
struct SimulateLocation(CoreDeviceServiceClient<Box<dyn ReadWrite>>);

impl RsdService for SimulateLocation {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.coredevice.locationservice")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> std::result::Result<Self, IdeviceError> {
        Ok(Self(CoreDeviceServiceClient::new(stream).await?))
    }
}
