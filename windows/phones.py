"""The iPhone side of changemylocation for Windows: list phones, then hand a location to one.

Set Location calls the phone's CoreDevice location service (the one Xcode's devicectl uses on a Mac). The phone's
own dtlocationd then runs the simulation with nothing connected, until Reset or a restart. Everything goes through
pymobiledevice3 over a userspace tunnel, so it needs no admin rights, only Apple's iPhone driver (the Apple Devices
app) and Developer Mode on the phone.
"""

import asyncio
import logging
from dataclasses import dataclass
from typing import Optional

from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.core_device.location_service import LocationService
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.usbmux import list_devices

logger = logging.getLogger("changemylocation")

FEATURE = "com.apple.coredevice.feature.simulatelocation"
SET = "com.apple.coredevice.action.setsimulatedlocation"
CLEAR = "com.apple.coredevice.action.clearsimulatedlocation"


@dataclass
class Phone:
    udid: str
    name: str
    connection: str  # "USB" or "Network"
    developer_mode: Optional[bool] = None  # None when the phone doesn't say


async def phones() -> list[Phone]:
    """The iPhones the iPhone driver sees, by cable or Wi-Fi, one entry each (USB preferred)."""
    found: dict[str, Phone] = {}
    for device in await list_devices():
        if device.serial in found and found[device.serial].connection == "USB":
            continue
        if device.serial in found:
            name, developer_mode = found[device.serial].name, found[device.serial].developer_mode
        else:
            name, developer_mode = await _info(device.serial)
        found[device.serial] = Phone(device.serial, name, device.connection_type, developer_mode)
    return sorted(found.values(), key=lambda p: p.name.lower())


async def _info(udid: str) -> tuple[str, Optional[bool]]:
    """The phone's name, and whether Developer Mode is on."""
    try:
        lockdown = await create_using_usbmux(serial=udid, autopair=False)
        try:
            name = lockdown.short_info.get("DeviceName") or f"iPhone {udid[-4:]}"
            try:
                developer_mode = bool(await lockdown.get_value("com.apple.security.mac.amfi", "DeveloperModeStatus"))
            except Exception:
                developer_mode = None
            return name, developer_mode
        finally:
            await lockdown.close()
    except Exception as e:  # not trusted yet, locked, or gone: still list it
        logger.info("couldn't read %s's details: %s", udid, e)
        return f"iPhone {udid[-4:]}", None


async def reveal_developer_mode(udid: str) -> None:
    """Shows the Developer Mode switch in Settings › Privacy & Security; iOS hides it until a developer tool connects."""
    lockdown = await create_using_usbmux(serial=udid, autopair=False)
    try:
        await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
    finally:
        await lockdown.close()


async def _invoke(udid: str, action: str, input_: dict) -> None:
    tunnel = UserspaceRsdTunnel(serial=udid)
    rsd = await asyncio.wait_for(tunnel.aopen(), 60)
    try:
        # Loads the developer tools if a restart unloaded them (devicectl does this silently on a Mac). On iOS 17+
        # this has to go through the tunnel.
        try:
            await auto_mount(rsd)
        except AlreadyMountedError:
            pass
        async with LocationService(rsd) as service:
            await service.invoke(FEATURE, input_, action_identifier=action)
    finally:
        await asyncio.wait_for(tunnel.aclose(), 10)


async def set_location(udid: str, latitude: float, longitude: float) -> None:
    """Hands the spot to the phone, which then holds it on its own until Reset or a restart."""
    await _invoke(udid, SET, {"latitude": float(latitude), "longitude": float(longitude)})


async def clear_location(udid: str) -> None:
    """Back to the real location. The phone has to be reachable (cable or same Wi-Fi)."""
    await _invoke(udid, CLEAR, {})
