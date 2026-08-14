from ..config import settings
from .uapi import AWGDevice

server_device = AWGDevice(settings.awg_iface, settings.awg_socket_dir)

_uplink_devices: dict[str, AWGDevice] = {}


def device_for(iface: str) -> AWGDevice:
    """A cached UAPI client per interface, so uplinks can be queried by name."""
    device = _uplink_devices.get(iface)
    if device is None:
        device = AWGDevice(iface, settings.awg_socket_dir)
        _uplink_devices[iface] = device
    return device


__all__ = ["AWGDevice", "server_device", "device_for"]
