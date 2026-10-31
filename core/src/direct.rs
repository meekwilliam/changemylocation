//! Talks to iPhones over USB without Apple's device service, through rusbmux. Used when that service isn't there,
//! which is a Windows PC without the Apple Devices app. The PC needs imsomeeked's USB driver installed once.
//!
//! Without Apple's service nothing remembers which computers a phone trusts, so this keeps its own pairing files
//! (one per phone) and its own host ID next to the developer disk image cache.

use std::{path::PathBuf, time::Duration};

use futures::StreamExt;
use idevice::pairing_file::PairingFile;
use rusbmux::{
    device::{Device, usb::UsbDevice},
    provider::RusbmuxProvider,
    watcher::{UsbEvent, preflight, watch_usb},
};

use crate::{Error, LABEL, Link, Phone, Result, cache_dir, device_name};

/// An open USB connection to one phone, paired and ready for idevice services.
pub struct Connected {
    pub udid: String,
    pub provider: RusbmuxProvider,
    device: UsbDevice,
}

impl Connected {
    /// Releases the phone's USB interface, so the next run (or another tool) can open it.
    pub async fn close(mut self) {
        let _ = self.device.shutdown().await;
    }
}

impl From<rusbmux::error::RusbmuxError> for Error {
    fn from(e: rusbmux::error::RusbmuxError) -> Self {
        Error::Other(format!("USB: {e}"))
    }
}

pub async fn phones() -> Result<Vec<Phone>> {
    let mut found = Vec::new();
    for phone in connect_all().await? {
        let name = device_name(&phone.provider)
            .await
            .unwrap_or_else(|| format!("iPhone {}", &phone.udid[phone.udid.len().saturating_sub(4)..]));
        found.push(Phone { udid: phone.udid.clone(), name, link: Link::Usb });
        phone.close().await;
    }
    Ok(found)
}

/// The phone with this UDID, or NotFound if it isn't plugged in.
pub async fn connect(udid: &str) -> Result<Connected> {
    let mut chosen = None;
    for phone in connect_all().await? {
        if chosen.is_none() && phone.udid == udid {
            chosen = Some(phone);
        } else {
            phone.close().await;
        }
    }
    chosen.ok_or_else(|| Error::NotFound(udid.to_string()))
}

/// Opens every iPhone plugged in right now. rusbmux reports the phones already connected first, then waits for
/// new ones, so a short pause after the last one means that's all of them.
async fn connect_all() -> Result<Vec<Connected>> {
    let mut events = watch_usb(&rusbmux::usb_backend::DEFAULT_BACKEND);
    let mut found = Vec::new();
    // Opening a phone can take a few seconds while it retries a busy interface.
    while let Ok(Some(event)) = tokio::time::timeout(Duration::from_secs(4), events.next()).await {
        let UsbEvent::Connected { device: Device::Usb(device), .. } = event? else { continue };
        let Some(udid) = device.udid().map(str::to_string) else { continue };
        let mut provider = RusbmuxProvider::new(&device, LABEL, Some(host_id().await?));
        provider.set_pairing_file(pairing_file(&device, &udid).await?);
        found.push(Connected { udid, provider, device });
    }
    Ok(found)
}

/// The saved pairing file for this phone, or a new one after the user taps Trust on it.
async fn pairing_file(device: &UsbDevice, udid: &str) -> Result<PairingFile> {
    let path = pairing_dir().join(format!("{udid}.plist"));
    let saved = PairingFile::read_from_file(&path).ok();
    match preflight(device.shared(), saved.as_ref(), &host_id().await?).await? {
        Some(new) => {
            tokio::fs::create_dir_all(pairing_dir()).await?;
            tokio::fs::write(&path, new.clone().serialize()?).await?;
            Ok(new)
        }
        None => saved.ok_or_else(|| {
            Error::Other("This iPhone doesn't trust this computer yet. Unlock it and tap Trust.".into())
        }),
    }
}

/// This computer's ID as the phone knows it. Pairing files are tied to it, so it's made once and kept.
async fn host_id() -> Result<String> {
    let path = cache_dir().join("host-id");
    if let Ok(id) = tokio::fs::read_to_string(&path).await
        && !id.trim().is_empty()
    {
        return Ok(id.trim().to_string());
    }
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    tokio::fs::create_dir_all(cache_dir()).await?;
    tokio::fs::write(&path, &id).await?;
    Ok(id)
}

fn pairing_dir() -> PathBuf {
    cache_dir().join("Pairing")
}
