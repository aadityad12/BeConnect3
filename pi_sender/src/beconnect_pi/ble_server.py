"""BlueZ D-Bus BLE peripheral implementation for BeConnect protocol."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any

from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method
from dbus_next import BusType, Variant

from .constants import (
    ALERT_CHAR_UUID,
    CONTROL_CHAR_UUID,
    MANUFACTURER_ID,
    SERVICE_UUID,
    metadata_payload,
)
from .model import AlertPacket
from .protocol import build_frames

LOGGER = logging.getLogger(__name__)
BLUEZ = "org.bluez"


@dataclass
class RuntimeState:
    alert: AlertPacket
    frames: list[bytes]
    requested_chunk_index: int = 0

    def update_alert(self, alert: AlertPacket) -> None:
        self.alert = alert
        self.frames = build_frames(alert)
        self.requested_chunk_index = 0

    def current_frame(self) -> bytes:
        idx = self.requested_chunk_index
        if idx < 0 or idx >= len(self.frames):
            return b""
        return self.frames[idx]


class BeConnectAdvertisement(ServiceInterface):
    def __init__(self, path: str, state: RuntimeState):
        super().__init__("org.bluez.LEAdvertisement1")
        self.path = path
        self.state = state

    @method()
    def Release(self) -> "":
        LOGGER.info("BlueZ requested advertisement release")

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":
        return "peripheral"

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":
        return [SERVICE_UUID]

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":
        return "BeConnect"

    @dbus_property(access=PropertyAccess.READ)
    def Includes(self) -> "as":
        return []

    @dbus_property(access=PropertyAccess.READ)
    def ManufacturerData(self) -> "a{qv}":
        payload = metadata_payload(
            self.state.alert.alertId,
            self.state.alert.severity,
            self.state.alert.fetchedAt,
        )
        return {MANUFACTURER_ID: Variant("ay", payload)}


class BeConnectService(ServiceInterface):
    def __init__(self, path: str):
        super().__init__("org.bluez.GattService1")
        self.path = path

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return SERVICE_UUID

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def Includes(self) -> "ao":
        return []


class AlertCharacteristic(ServiceInterface):
    def __init__(self, path: str, service_path: str, state: RuntimeState):
        super().__init__("org.bluez.GattCharacteristic1")
        self.path = path
        self.service_path = service_path
        self.state = state

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return ALERT_CHAR_UUID

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":
        return self.service_path

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":
        return ["read"]

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":
        frame = self.state.current_frame()
        LOGGER.info(
            "Served chunk index=%s total=%s bytes=%s",
            self.state.requested_chunk_index,
            len(self.state.frames),
            len(frame),
        )
        return frame


class ControlCharacteristic(ServiceInterface):
    def __init__(self, path: str, service_path: str, state: RuntimeState):
        super().__init__("org.bluez.GattCharacteristic1")
        self.path = path
        self.service_path = service_path
        self.state = state

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return CONTROL_CHAR_UUID

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":
        return self.service_path

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":
        return ["write"]

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}") -> "":
        if len(value) < 2:
            LOGGER.warning("CONTROL write too short (%s bytes)", len(value))
            return
        idx = ((value[0] & 0xFF) << 8) | (value[1] & 0xFF)
        self.state.requested_chunk_index = idx
        LOGGER.info("Chunk request received index=%s total=%s", idx, len(self.state.frames))


class BeConnectApplication(ServiceInterface):
    def __init__(
        self,
        path: str,
        service: BeConnectService,
        alert_char: AlertCharacteristic,
        control_char: ControlCharacteristic,
    ):
        super().__init__("org.freedesktop.DBus.ObjectManager")
        self.path = path
        self.service = service
        self.alert_char = alert_char
        self.control_char = control_char

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":
        return {
            self.service.path: {
                "org.bluez.GattService1": {
                    "UUID": Variant("s", SERVICE_UUID),
                    "Primary": Variant("b", True),
                    "Includes": Variant("ao", []),
                }
            },
            self.alert_char.path: {
                "org.bluez.GattCharacteristic1": {
                    "UUID": Variant("s", ALERT_CHAR_UUID),
                    "Service": Variant("o", self.service.path),
                    "Flags": Variant("as", ["read"]),
                }
            },
            self.control_char.path: {
                "org.bluez.GattCharacteristic1": {
                    "UUID": Variant("s", CONTROL_CHAR_UUID),
                    "Service": Variant("o", self.service.path),
                    "Flags": Variant("as", ["write"]),
                }
            },
        }


class BluezBeConnectServer:
    """Owns BlueZ advertisement + GATT application registration lifecycle."""

    def __init__(self, initial_alert: AlertPacket):
        frames = build_frames(initial_alert)
        self.state = RuntimeState(initial_alert, frames)

        self.bus: MessageBus | None = None
        self.adapter_path: str | None = None

        self.app_path = "/com/beconnect/app"
        self.service_path = f"{self.app_path}/service0"
        self.alert_path = f"{self.service_path}/char0"
        self.control_path = f"{self.service_path}/char1"
        self.advert_path = "/com/beconnect/advert0"

        self.app: BeConnectApplication | None = None
        self.service: BeConnectService | None = None
        self.alert_char: AlertCharacteristic | None = None
        self.control_char: ControlCharacteristic | None = None
        self.advert: BeConnectAdvertisement | None = None

        self._gatt_iface = None
        self._adv_iface = None
        self._props_iface = None

    async def start(self) -> None:
        self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        self.adapter_path = await self._find_adapter(self.bus)
        await self._set_adapter_powered(self.bus, self.adapter_path, True)
        await self._bind_manager_ifaces(self.bus, self.adapter_path)

        self.service = BeConnectService(self.service_path)
        self.alert_char = AlertCharacteristic(self.alert_path, self.service_path, self.state)
        self.control_char = ControlCharacteristic(self.control_path, self.service_path, self.state)
        self.app = BeConnectApplication(self.app_path, self.service, self.alert_char, self.control_char)
        self.advert = BeConnectAdvertisement(self.advert_path, self.state)

        self.bus.export(self.app_path, self.app)
        self.bus.export(self.service_path, self.service)
        self.bus.export(self.alert_path, self.alert_char)
        self.bus.export(self.control_path, self.control_char)
        self.bus.export(self.advert_path, self.advert)

        await self._gatt_iface.call_register_application(self.app_path, {})
        await self._adv_iface.call_register_advertisement(self.advert_path, {})

        LOGGER.info(
            "BLE started adapter=%s alert=%s headline=%s chunks=%s",
            self.adapter_path,
            self.state.alert.alertId,
            self.state.alert.headline,
            len(self.state.frames),
        )

    async def stop(self) -> None:
        if self.bus is None:
            return

        try:
            if self._adv_iface is not None:
                await self._adv_iface.call_unregister_advertisement(self.advert_path)
        except Exception as exc:  # noqa: BLE001
            LOGGER.warning("UnregisterAdvertisement failed: %s", exc)

        try:
            if self._gatt_iface is not None:
                await self._gatt_iface.call_unregister_application(self.app_path)
        except Exception as exc:  # noqa: BLE001
            LOGGER.warning("UnregisterApplication failed: %s", exc)

        for path in [self.advert_path, self.control_path, self.alert_path, self.service_path, self.app_path]:
            try:
                self.bus.unexport(path)
            except Exception:  # noqa: BLE001
                pass

        self.bus.disconnect()
        self.bus = None
        LOGGER.info("BLE stopped")

    async def update_alert(self, alert: AlertPacket) -> None:
        self.state.update_alert(alert)
        LOGGER.info(
            "Loaded published alert=%s severity=%s chunks=%s",
            alert.alertId,
            alert.severity,
            len(self.state.frames),
        )
        if self._adv_iface is not None:
            await self._adv_iface.call_unregister_advertisement(self.advert_path)
            await asyncio.sleep(0.05)
            await self._adv_iface.call_register_advertisement(self.advert_path, {})
            LOGGER.info("Advertisement metadata updated for alert=%s", alert.alertId)

    async def _find_adapter(self, bus: MessageBus) -> str:
        introspection = await bus.introspect(BLUEZ, "/")
        obj = bus.get_proxy_object(BLUEZ, "/", introspection)
        manager = obj.get_interface("org.freedesktop.DBus.ObjectManager")
        managed: dict[str, dict[str, Any]] = await manager.call_get_managed_objects()

        for path, ifaces in managed.items():
            if "org.bluez.GattManager1" in ifaces and "org.bluez.LEAdvertisingManager1" in ifaces:
                return path
        raise RuntimeError("No BLE adapter found with GattManager1 + LEAdvertisingManager1")

    async def _set_adapter_powered(self, bus: MessageBus, adapter_path: str, powered: bool) -> None:
        introspection = await bus.introspect(BLUEZ, adapter_path)
        obj = bus.get_proxy_object(BLUEZ, adapter_path, introspection)
        props = obj.get_interface("org.freedesktop.DBus.Properties")
        await props.call_set("org.bluez.Adapter1", "Powered", Variant("b", powered))

    async def _bind_manager_ifaces(self, bus: MessageBus, adapter_path: str) -> None:
        introspection = await bus.introspect(BLUEZ, adapter_path)
        obj = bus.get_proxy_object(BLUEZ, adapter_path, introspection)
        self._gatt_iface = obj.get_interface("org.bluez.GattManager1")
        self._adv_iface = obj.get_interface("org.bluez.LEAdvertisingManager1")
        self._props_iface = obj.get_interface("org.freedesktop.DBus.Properties")
