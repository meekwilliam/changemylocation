#!/usr/bin/env python3
"""Set a simulated GPS location on a USB-connected iPhone (developer testing).

Uses Apple's developer location-simulation service (the same one Xcode uses)
via pymobiledevice3. Requires Developer Mode on the iPhone.

Usage:
  python3 iphone_location.py set 40.7580 -73.9855
  python3 iphone_location.py preset nyc
  python3 iphone_location.py clear
"""
import subprocess
import sys

PRESETS = {
    "nyc": (40.7580, -73.9855),
    "sf": (37.7749, -122.4194),
    "london": (51.5074, -0.1278),
    "tokyo": (35.6762, 139.6503),
    "apple-park": (37.3349, -122.0090),
}

BASE = ["pymobiledevice3", "developer", "dvt", "simulate-location"]


def run(args):
    # --tunnel '' picks the first device exposed by `pymobiledevice3 remote tunneld` (iOS 17+)
    cmd = BASE + args[:1] + ["--tunnel", ""] + args[1:]
    try:
        subprocess.run(cmd, check=True)
    except FileNotFoundError:
        sys.exit("pymobiledevice3 not found. Install it: python3 -m pip install -U pymobiledevice3")
    except subprocess.CalledProcessError:
        sys.exit(
            "Failed. Check: iPhone unlocked and trusted, Developer Mode on, and\n"
            "`sudo pymobiledevice3 remote tunneld` running in another terminal."
        )


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    action = sys.argv[1]
    if action == "set" and len(sys.argv) == 4:
        lat, lon = float(sys.argv[2]), float(sys.argv[3])
    elif action == "preset" and len(sys.argv) == 3 and sys.argv[2] in PRESETS:
        lat, lon = PRESETS[sys.argv[2]]
    elif action == "clear":
        run(["clear"])
        print("Location restored to real GPS.")
        return
    else:
        sys.exit(__doc__ + "\nPresets: " + ", ".join(PRESETS))
    run(["set", "--", str(lat), str(lon)])
    print(f"Location set to {lat}, {lon}. Run `clear` to restore.")


if __name__ == "__main__":
    main()
