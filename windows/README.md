# imsomeeked for Windows (beta)

The Windows version of imsomeeked works the same way as the Mac app. It hands the location to the iPhone, which then holds it **on its own** until you press **Reset** or restart the phone. Instead of Xcode, it talks to the phone through [pymobiledevice3](https://github.com/doronz88/pymobiledevice3).

## Requirements

- Windows 10 or 11.
- **Apple Devices** from the Microsoft Store, or iTunes. It provides the iPhone's USB driver.
- An iPhone with **Developer Mode** on, running iOS 17 or later.
- An internet connection the first time you use each iPhone, and after it restarts. imsomeeked downloads Apple's developer tools for the phone, the same files Xcode uses.

## Install

1. Download `imsomeeked.exe` from [Releases](../../../releases). Development builds are under **Actions › Windows build** as `imsomeeked-windows`.
2. Run it. Windows SmartScreen may warn that the app is unrecognized because it isn't code-signed. Choose **More info › Run anyway**.

## Set up your iPhone (once)

1. Plug the iPhone into the PC, unlock it, and tap **Trust**.
2. Turn on **Developer Mode** in **Settings › Privacy & Security › Developer Mode**, then let the phone restart. If you don't see the option, connect the phone to a Mac with Xcode once, or use `pymobiledevice3 amfi reveal-developer-mode`.
3. Optional: to use Wi-Fi instead of a cable, open Apple Devices, select the phone, and turn on **Show this iPhone when on Wi-Fi**.

## Use

Pick a spot by searching or clicking the map, then press **Set Location**. When it says the iPhone holds it on its own, you can unplug the phone or close the app. Press **↺** to go back to the real location; the phone has to be reachable for this. Restarting the iPhone also clears it.

The app remembers each phone's last spot in `%APPDATA%\imsomeeked\state.json` and logs each Set and Reset to `imsomeeked.log` in the same folder.

## Run from source

```sh
cd windows
pip install -r requirements.txt
python imsomeeked.py
```

Search and the map use [OpenStreetMap](https://www.openstreetmap.org/copyright) data and its Nominatim search service. The map is drawn with [Leaflet](https://leafletjs.com) (BSD-2-Clause, bundled in `web/vendor/leaflet`).
