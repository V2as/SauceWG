from ..config import settings
from .uapi import AWGDevice

server_device = AWGDevice(settings.awg_iface, settings.awg_socket_dir)
cascade_device = AWGDevice(settings.cascade_iface, settings.awg_socket_dir)

__all__ = ["AWGDevice", "server_device", "cascade_device"]
