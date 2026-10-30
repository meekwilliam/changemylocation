"""The iPhone side of imsomeeked for Windows: list phones, then hand a location to one.

Set Location calls the phone's CoreDevice location service (the one Xcode's devicectl uses on a Mac). The phone's
own dtlocationd then runs the simulation with nothing connected, until Reset or a restart. Everything goes through
pymobiledevice3 over a userspace tunnel, so it needs no admin rights, only Apple's iPhone driver (the Apple Devices
app) and Developer Mode on the phone.
"""

import asyncio
import logging
from dataclasses import dataclass

from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.core_device.location_service import LocationService
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.usbmux import list_devices

logger = logging.getLogger("imsomeeked")

FEATURE = "com.apple.coredevice.feature.simulatelocation"
SET = "com.apple.coredevice.action.setsimulatedlocation"
CLEAR = "com.apple.coredevice.action.clearsimulatedlocation"


@dataclass
class Phone:
    udid: str
    name: str
    connection: str  # "USB" or "Network"


async def phones() -> list[Phone]:
    """The iPhones the iPhone driver sees, by cable or Wi-Fi, one entry each (USB preferred)."""
    found: dict[str, Phone] = {}
    for device in await list_devices():
        if device.serial in found and found[device.serial].connection == "USB":
            continue
        name = found[device.serial].name if device.serial in found else await _name(device.serial)
        found[device.serial] = Phone(device.serial, name, device.connection_type)
    return sorted(found.values(), key=lambda p: p.name.lower())


async def _name(udid: str) -> str:
    try:
        lockdown = await create_using_usbmux(serial=udid, autopair=False)
        try:
            return lockdown.short_info.get("DeviceName") or f"iPhone {udid[-4:]}"
        finally:
            await lockdown.close()
    except Exception as e:  # not trusted yet, locked, or gone: still list it
        logger.info("couldn't read %s's name: %s", udid, e)
        return f"iPhone {udid[-4:]}"


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
