"""imsomeeked for Windows: a map window for setting a simulated location on your own iPhone.

The window is a small web page (web/) shown with pywebview; it calls the Api methods below, which talk to the
phone through phones.py. Each phone's last spot is remembered in %APPDATA%\\imsomeeked\\state.json, and every Set
and Reset is logged next to it.
"""

import asyncio
import json
import logging
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import webview

import phones

APP_DIR = Path(os.environ.get("APPDATA", Path.home() / ".config")) / "imsomeeked"
STATE = APP_DIR / "state.json"
APP_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(filename=APP_DIR / "imsomeeked.log", level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("imsomeeked")

# OpenStreetMap's Nominatim asks every app to identify itself.
USER_AGENT = "imsomeeked/1.0 (+https://github.com/meekwilliam/imsomeeked)"


def web_dir() -> Path:
    # PyInstaller unpacks bundled files to sys._MEIPASS.
    return Path(getattr(sys, "_MEIPASS", Path(__file__).parent)) / "web"


def with_retries(make_call):
    """A locked iPhone on Wi-Fi drops in and out of view for a few seconds at a time, so retry briefly."""
    for attempt in range(4):
        try:
            return asyncio.run(make_call())
        except Exception as e:
            if attempt == 3 or not (type(e).__name__ == "DeviceNotFoundError"
                                    or isinstance(e, (TimeoutError, ConnectionError))):
                raise
            logger.info("phone not reachable (%s); retrying", type(e).__name__)
            time.sleep(5)


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    STATE.write_text(json.dumps(state, indent=2))


def error_text(e: Exception) -> str:
    text = str(e) or type(e).__name__
    if type(e).__name__ == "DeviceNotFoundError" or isinstance(e, (TimeoutError, ConnectionError)):
        return "Can't reach this iPhone right now. Unlock it, or plug it in, and try again."
    if "DeveloperMode" in text or "Developer Mode" in text:
        return "Developer Mode is off on this iPhone. Turn it on in Settings › Privacy & Security."
    if "NotPaired" in type(e).__name__ or "trust" in text.lower():
        return "This iPhone doesn't trust this PC yet. Plug it in, unlock it, and tap Trust."
    return text


class Api:
    """Called from the page (window.pywebview.api.*). pywebview runs each call on its own thread."""

    def phones(self):
        try:
            found = asyncio.run(phones.phones())
        except Exception as e:  # driver missing or not running
            logger.warning("listing phones failed: %s", e)
            return {"error": "Can't see any iPhones. Install Apple Devices from the Microsoft Store, then plug in your iPhone."}
        last = load_state()
        return [{"udid": p.udid, "name": p.name, "connection": p.connection, "last": last.get(p.udid)} for p in found]

    def set(self, udid: str, lat: float, lon: float, name: str = "") -> dict:
        logger.info("[%s] Set Location pressed (%.5f, %.5f)", udid[-4:], lat, lon)
        try:
            with_retries(lambda: phones.set_location(udid, lat, lon))
        except Exception as e:
            logger.exception("[%s] set failed", udid[-4:])
            return {"ok": False, "message": error_text(e)}
        state = load_state()
        state[udid] = {"lat": lat, "lon": lon, "name": name}
        save_state(state)
        return {"ok": True, "message": f"Location set to {lat:.5f}, {lon:.5f}. The iPhone holds it on its own until Reset or a restart."}

    def clear(self, udid: str) -> dict:
        logger.info("[%s] Reset pressed", udid[-4:])
        try:
            with_retries(lambda: phones.clear_location(udid))
        except Exception as e:
            logger.exception("[%s] reset failed", udid[-4:])
            return {"ok": False, "message": "Couldn't reach the iPhone to reset it: " + error_text(e)}
        state = load_state()
        state.pop(udid, None)
        save_state(state)
        return {"ok": True, "message": "Restored the real location."}

    def search(self, query: str) -> list:
        url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(
            {"q": query, "format": "jsonv2", "limit": 6})
        return [{"name": r.get("name") or r["display_name"].split(",")[0], "subtitle": r["display_name"],
                 "lat": float(r["lat"]), "lon": float(r["lon"])} for r in self._get(url)]

    def describe(self, lat: float, lon: float) -> dict:
        url = "https://nominatim.openstreetmap.org/reverse?" + urllib.parse.urlencode(
            {"lat": lat, "lon": lon, "format": "jsonv2", "zoom": 18})
        r = self._get(url) or {}
        return {"name": r.get("name") or "Dropped pin", "subtitle": r.get("display_name", "")}

    @staticmethod
    def _get(url: str):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=10) as r:
                return json.load(r)
        except Exception as e:
            logger.warning("lookup failed: %s", e)
            return []


def selftest() -> int:
    """`imsomeeked --selftest`: checks the build bundled everything (used by CI, where no window can open). The
    exe has no console, so the result goes to %APPDATA%\\imsomeeked\\selftest.txt."""
    try:
        import pymobiledevice3.remote.core_device.location_service  # noqa: F401
        import pymobiledevice3.remote.userspace_tunnel  # noqa: F401
        import pymobiledevice3.services.mobile_image_mounter  # noqa: F401
    except Exception:
        import traceback
        (APP_DIR / "selftest.txt").write_text(traceback.format_exc())
        return 1
    missing = [f for f in ("index.html", "app.js", "style.css", "vendor/leaflet/leaflet.js") if not (web_dir() / f).is_file()]
    (APP_DIR / "selftest.txt").write_text("missing: " + ", ".join(missing) if missing else "ok")
    return 1 if missing else 0


def close_splash() -> None:
    """Closes the "Starting…" card the exe shows while it unpacks (only there in the PyInstaller build)."""
    try:
        import pyi_splash
        pyi_splash.close()
    except ImportError:
        pass


def main() -> None:
    if "--selftest" in sys.argv:
        close_splash()
        sys.exit(selftest())
    # Stay hidden until the page has drawn, so the window doesn't open blank and then fill in.
    window = webview.create_window("imsomeeked", str(web_dir() / "index.html"), js_api=Api(),
                                   width=1100, height=760, min_size=(760, 560), hidden=True)

    def show() -> None:
        close_splash()
        window.show()

    window.events.loaded += show
    webview.start()


if __name__ == "__main__":
    main()
