# imsomeeked: iPhone location simulator for Mac and Windows

**Set a simulated GPS location on your own iPhone, for free.** You don't need a jailbreak or an app on the phone, and once the location is set, the iPhone **keeps it on its own**, even after you unplug it, lock it, or close your computer. Works with **iOS 17, 18, 26 and 27**.

<p>
  <a href="https://github.com/meekwilliam/imsomeeked/releases/latest/download/imsomeeked.zip"><img alt="Download for macOS" src="https://img.shields.io/badge/Download_for-macOS-1f6feb?style=for-the-badge"></a>
  &nbsp;
  <a href="https://github.com/meekwilliam/imsomeeked/releases/latest/download/imsomeeked.exe"><img alt="Download for Windows (beta)" src="https://img.shields.io/badge/Download_for-Windows_(beta)-1f6feb?style=for-the-badge"></a>
</p>

[![Latest release](https://img.shields.io/github/v/release/meekwilliam/imsomeeked)](https://github.com/meekwilliam/imsomeeked/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/meekwilliam/imsomeeked/total)](https://github.com/meekwilliam/imsomeeked/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Windows-lightgrey)
![iOS](https://img.shields.io/badge/iOS-17%2B-lightgrey)

<!-- Screenshot: add docs/screenshot.png here -->

<details>
<summary><b>Table of contents</b></summary>

- [Features](#features)
- [How it compares](#how-it-compares)
- [Requirements](#requirements)
- [Install](#install)
- [Set up your iPhone](#set-up-your-iphone-once)
- [Use](#use)
- [FAQ](#faq)
- [How it works](#how-it-works)
- [Build from source](#build-from-source)
- [Contributing](#contributing)
- [Responsible use](#responsible-use)
- [License](#license)
</details>

## Features

- **Change your iPhone's GPS location** to anywhere: search an address or place, click the map, or paste coordinates (`lat, lon`).
- **Holds the location without staying connected.** The iPhone runs the simulation itself, so you can unplug it, lock it, take it off your Wi-Fi, or close the laptop.
- **No jailbreak, and nothing to install on the iPhone.**
- **iOS 17 and later**, including iOS 18, iOS 26 and iOS 27.
- **Works over a USB cable or Wi-Fi.**
- **Several iPhones at once**, each in its own tab.
- **One-click reset** back to your real location. Restarting the iPhone also resets it.

After the iPhone restarts, plug it in and unlock it the first time you set a location, so imsomeeked can load the phone's developer tools. After that, Wi-Fi works again.
- **Remembers each phone's last spot**, so it's quick to set again after a restart.
- **macOS and Windows (beta).** Free and open source.

## How it compares

| | imsomeeked | Older spoofing tools | Live-connection tools |
|---|---|---|---|
| iOS 17 and later | ✅ | ❌ often broken | ✅ |
| Keeps the location after unplugging or sleeping | ✅ | varies | ❌ drops back to real GPS |
| Jailbreak needed | No | Sometimes | No |
| App on the iPhone | No | Sometimes | Sometimes |
| Price | Free, open source | Often paid | Varies |

## Requirements

| | macOS | Windows (beta) |
|---|---|---|
| Computer | macOS 26 or later | Windows 10 or 11 |
| Extra software | None | **Apple Devices** from the Microsoft Store, or iTunes |
| iPhone | iOS 17 or later, **Developer Mode** on | iOS 17 or later, **Developer Mode** on |

imsomeeked is tested on iOS 27.

## Install

**macOS:** [Download `imsomeeked.zip`](https://github.com/meekwilliam/imsomeeked/releases/latest/download/imsomeeked.zip), unzip it, and move **imsomeeked** to Applications. The app isn't notarized by Apple, so the first time, **right-click it and choose Open**, then confirm. You can also run `xattr -dr com.apple.quarantine /Applications/imsomeeked.app`.

**Windows (beta):** [Download `imsomeeked.exe`](https://github.com/meekwilliam/imsomeeked/releases/latest/download/imsomeeked.exe) and run it. SmartScreen may warn that it's unrecognized, because it isn't code-signed. Choose **More info › Run anyway**. See the [Windows setup](windows#readme).

## Set up your iPhone (once)

1. Plug the iPhone into your computer, unlock it, and tap **Trust**.
2. Turn on **Developer Mode** in **Settings › Privacy & Security › Developer Mode**, then let the phone restart.
3. Optional, to set locations over Wi-Fi without a cable:
   - **Mac:** in Finder, select the iPhone in the sidebar and check **Show this iPhone when on Wi-Fi**.
   - **Windows:** in Apple Devices, turn on **Show this iPhone when on Wi-Fi**.

## Use

1. Search for a place, click the map, or paste coordinates. On a Mac you can also right-click the map.
2. Press **Set Location**. When it says the iPhone holds the location on its own, you can disconnect.
3. To go back to your real location, press **Reset** (↺). The phone has to be reachable for this, by cable or on the same Wi-Fi. Restarting the iPhone also resets it.

After the iPhone restarts, plug it in and unlock it the first time you set a location, so imsomeeked can load the phone's developer tools. After that, Wi-Fi works again.

## FAQ

**Do I need to jailbreak my iPhone?**
No. imsomeeked uses Apple's developer location simulation, the same feature Xcode uses.

**Does the iPhone have to stay connected to the computer?**
No. Once the location is set, the iPhone holds it by itself. In testing, it held for over 9 hours with the Mac asleep and the iPhone locked on battery, with no interruptions in the phone's own log.

**Which iOS versions work?**
iOS 17 and later. It's tested on iOS 27.

**How do I get my real location back?**
Press **Reset** with the phone reachable, or restart the iPhone.

**Why does an app still show the old location?**
Some apps keep the last location they received, so close the app fully and reopen it. A few apps deliberately ignore simulated locations.

**Do I need Xcode?**
No. The Mac app talks to the iPhone directly with its own engine, so you don't need Xcode or any other developer software.

**Is it safe?**
It only changes the location your iPhone reports, and restarting the iPhone undoes it. The code is open source, so you can read exactly what it does.

## How it works

On a Mac, imsomeeked's engine ([`core/`](core), Rust, built on [idevice](https://github.com/jkcoxson/idevice)) opens Apple's developer tunnel to the iPhone, loads the phone's developer tools if a restart unloaded them, and asks it to simulate the location. On Windows, it calls the same Apple service through [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Either way, the location is handed to the iPhone's own location-simulation service (`com.apple.coredevice.locationservice`), and the phone then runs the simulation itself.

Many tools instead keep a live developer connection open the whole time. A locked iPhone's Wi-Fi naps, and the computer tears down its connection to a quiet phone. Either one ends a live session and sends the iPhone back to real GPS, which shows up as the location "jumping back". imsomeeked has no connection to lose.

## Build from source

**macOS**, which needs Swift (Xcode or the Command Line Tools) and [Rust](https://rustup.rs) with both Mac targets (`rustup target add aarch64-apple-darwin x86_64-apple-darwin`):

```sh
./build.sh          # builds imsomeeked.app
./build.sh --zip    # also makes imsomeeked.zip for a release
```

**Windows:** see [`windows/`](windows#readme). The `.exe` is built by GitHub Actions ([`.github/workflows/windows.yml`](.github/workflows/windows.yml)).

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](.github/CONTRIBUTING.md), open an [issue](https://github.com/meekwilliam/imsomeeked/issues), or ask in [Discussions](https://github.com/meekwilliam/imsomeeked/discussions).

## Responsible use

imsomeeked is meant for developing and testing apps on devices you own. Respect the terms of the apps and services you use, many of which forbid location spoofing, and don't use it to mislead people who rely on your location. You're responsible for how you use it.

imsomeeked is an independent project and isn't affiliated with or endorsed by Apple. Apple, iPhone and Xcode are trademarks of Apple Inc.

## Acknowledgements

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3), for talking to iPhones on Windows.
- [Leaflet](https://leafletjs.com) and [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, for the Windows map and search.

## License

imsomeeked's source code is [MIT licensed](LICENSE). The Windows `.exe` bundles pymobiledevice3 and other GPL-3.0 libraries, so the Windows build as a whole is distributed under the [GPL-3.0](windows/COPYING.GPL-3.0.txt). Its full third-party license list ships with each release.
