# imsomeeked

A free macOS app for setting a simulated location on your own iPhone, for testing location-based apps.

Pick a spot on the map and press **Set Location**. The iPhone then holds that location **on its own**. You can unplug it, take it off your Wi-Fi, lock it, or close your Mac, and it keeps reporting the simulated spot to every app until you press **Reset** or restart the phone.

> **Windows?** There's a beta Windows version in [`windows/`](windows). It works the same way, using pymobiledevice3 instead of Xcode.

## Requirements

- A Mac with **macOS 26** or later.
- **Xcode 26** or later, installed and opened once. imsomeeked uses Xcode's `devicectl` tool.
- An iPhone with **Developer Mode** on. imsomeeked is tested on iOS 27, and `devicectl` needs iOS 17 or later.

## Install

1. Download `imsomeeked.zip` from [Releases](../../releases), unzip it, and move **imsomeeked** to Applications.
2. The app isn't notarized by Apple, so the first time, **right-click it and choose Open**, then confirm. You can also run this in Terminal: `xattr -dr com.apple.quarantine /Applications/imsomeeked.app`.

## Set up your iPhone (once)

1. Plug the iPhone into your Mac, unlock it, and tap **Trust**.
2. Turn on **Developer Mode** in **Settings › Privacy & Security › Developer Mode**, then let the phone restart. If you don't see the option, open Xcode with the phone plugged in, and it will appear.
3. Optional: to set locations without a cable, open Xcode's **Window › Devices and Simulators**, select the phone, and check **Connect via network**.

## Use

- Pick a place by searching, clicking the map, or right-clicking it, then press **Set Location**. When it says the iPhone holds it on its own, you can disconnect.
- Press **Reset** (↺) to go back to the real location. The phone has to be reachable for this, either plugged in or on the same Wi-Fi.
- **Restarting the iPhone** also clears the simulated location, with no Mac needed. imsomeeked remembers each phone's last spot, so setting it again is one click.
- Several iPhones work at once. Each one gets its own tab.

## How it works

imsomeeked calls `xcrun devicectl device simulate location coordinate`. That hands the location to the iPhone's own location-simulation service, the same one Xcode uses. The phone then runs the simulation itself, so nothing has to stay connected, and there's no connection to drop when the phone sleeps or leaves your Wi-Fi.

An earlier version kept a live developer session open from the Mac. A locked iPhone's Wi-Fi naps, and macOS tears down its tunnel to the phone, and either one ended that session and sent the phone back to real GPS. The phone-held simulation has no such dependency. In testing, it held for over 9 hours with the Mac asleep and the phone locked on battery, with zero interruptions in the phone's own log.

Each Set and Reset is logged to `~/Library/Logs/imsomeeked.log`.

## Build from source

```sh
./build.sh          # builds imsomeeked.app
./build.sh --zip    # also makes imsomeeked.zip for a release
```

Requires the Swift toolchain that comes with Xcode 26.

## Limits

- Setting or resetting a location needs the iPhone reachable, by cable or on the same Wi-Fi with the phone awake.
- Some apps keep the last location they received, so close and reopen them. A few apps deliberately ignore simulated locations.
- Only the GPS position is simulated, not motion sensor data.

## Responsible use

imsomeeked is meant for developing and testing apps on devices you own. Respect the terms of the apps and services you use, many of which forbid location spoofing, and don't use it to mislead people who rely on your location. You're responsible for how you use it.

imsomeeked is an independent project and isn't affiliated with or endorsed by Apple. Apple, iPhone and Xcode are trademarks of Apple Inc.

## License

[MIT](LICENSE)
