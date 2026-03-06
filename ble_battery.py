#!/usr/bin/env python3
"""
BLE Battery Service reader for Razer mice on macOS.

Uses CoreBluetooth to read the standard Battery Service (0x180F) from
paired Razer BLE HID devices. macOS hides paired BLE HID devices from
normal BLE scans, so we use retrieveConnectedPeripheralsWithServices
to find already-connected peripherals.

Requires: pyobjc-framework-CoreBluetooth
"""

import threading
import time
from typing import Optional

try:
    import objc
    from CoreBluetooth import (
        CBCentralManager,
        CBUUID,
    )
    from Foundation import NSRunLoop, NSDate, NSObject
    HAS_COREBLUETOOTH = True
except ImportError:
    HAS_COREBLUETOOTH = False

# Standard BLE service/characteristic UUIDs
BATTERY_SERVICE_UUID = "180F"
BATTERY_LEVEL_CHAR_UUID = "2A19"
HID_SERVICE_UUID = "1812"
DEVICE_INFO_SERVICE_UUID = "180A"
PNP_ID_CHAR_UUID = "2A50"

# Razer vendor-specific GATT service (found on Basilisk V3 X HS and BlackWidow V3 Mini)
RAZER_VENDOR_SERVICE_UUID = "52401523-F97C-7F90-0E7F-6C6F4E36DB1C"

# Keywords to match Razer device names
RAZER_NAME_KEYWORDS = ['razer', 'basilisk', 'bsk', 'deathadder', 'viper']


class BLERazerBattery:
    """Read battery level from a Razer mouse via BLE Battery Service."""

    def __init__(self, debug: bool = False):
        if not HAS_COREBLUETOOTH:
            raise ImportError(
                "CoreBluetooth not available. Install pyobjc-framework-CoreBluetooth:\n"
                "  pip install pyobjc-framework-CoreBluetooth"
            )
        self.debug = debug
        self._battery_level: Optional[int] = None
        self._done = threading.Event()
        self._peripheral = None
        self._manager = None

    def _dbg(self, msg: str) -> None:
        if self.debug:
            print(f"[ble-debug] {msg}")

    def read_battery(self, timeout_s: float = 5.0) -> Optional[int]:
        """
        Read battery level from a paired Razer BLE device.

        Returns battery percentage (0-100) or None if not found/unavailable.
        Thread-safe: runs CoreBluetooth on its own NSRunLoop internally.
        """
        self._battery_level = None
        self._done.clear()

        thread = threading.Thread(target=self._run_ble, daemon=True)
        thread.start()
        self._done.wait(timeout=timeout_s)

        return self._battery_level

    def _run_ble(self):
        """Run the CoreBluetooth flow on a thread with NSRunLoop."""
        delegate = _CBDelegate.alloc().initWithOwner_(self)
        self._manager = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)

        deadline = time.time() + 10.0
        while not self._done.is_set() and time.time() < deadline:
            NSRunLoop.currentRunLoop().runUntilDate_(
                NSDate.dateWithTimeIntervalSinceNow_(0.1)
            )

        if self._peripheral and self._manager:
            try:
                self._manager.cancelPeripheralConnection_(self._peripheral)
            except Exception:
                pass

    def _on_powered_on(self):
        """Called when CBCentralManager reaches PoweredOn state."""
        self._dbg("CoreBluetooth powered on")

        # Find already-connected peripherals with Battery Service.
        # This is the key to finding paired BLE HID devices on macOS -
        # they don't appear in normal scans.
        battery_uuid = CBUUID.UUIDWithString_(BATTERY_SERVICE_UUID)
        peripherals = self._manager.retrieveConnectedPeripheralsWithServices_([battery_uuid])
        self._dbg(f"Found {len(peripherals)} peripherals with Battery Service")

        if not peripherals:
            hid_uuid = CBUUID.UUIDWithString_(HID_SERVICE_UUID)
            peripherals = self._manager.retrieveConnectedPeripheralsWithServices_([hid_uuid])
            self._dbg(f"Found {len(peripherals)} peripherals with HID Service")

        for peripheral in peripherals:
            name = peripheral.name() or ""
            self._dbg(f"  Peripheral: {name} ({peripheral.identifier()})")

            name_lower = name.lower()
            if any(kw in name_lower for kw in RAZER_NAME_KEYWORDS):
                self._dbg(f"  -> Matched Razer device: {name}")
                self._peripheral = peripheral
                self._manager.connectPeripheral_options_(peripheral, None)
                return

        self._dbg("No Razer BLE device found among connected peripherals")
        self._done.set()

    def _on_connected(self, peripheral):
        """Called when peripheral connection succeeds."""
        self._dbg(f"Connected to {peripheral.name()}")
        battery_uuid = CBUUID.UUIDWithString_(BATTERY_SERVICE_UUID)
        peripheral.discoverServices_([battery_uuid])

    def _on_services_discovered(self, peripheral):
        """Called when GATT services are discovered."""
        for service in peripheral.services() or []:
            self._dbg(f"  Service: {service.UUID()}")
            if service.UUID().UUIDString().upper() == BATTERY_SERVICE_UUID:
                char_uuid = CBUUID.UUIDWithString_(BATTERY_LEVEL_CHAR_UUID)
                peripheral.discoverCharacteristics_forService_([char_uuid], service)

    def _on_characteristics_discovered(self, peripheral, service):
        """Called when GATT characteristics are discovered."""
        for char in service.characteristics() or []:
            self._dbg(f"  Characteristic: {char.UUID()}")
            if char.UUID().UUIDString().upper() == BATTERY_LEVEL_CHAR_UUID:
                peripheral.readValueForCharacteristic_(char)

    def _on_characteristic_read(self, peripheral, characteristic):
        """Called when a characteristic value is read."""
        value = characteristic.value()
        if value and len(value) >= 1:
            self._battery_level = value[0]
            self._dbg(f"Battery level: {self._battery_level}%")
        self._done.set()


if HAS_COREBLUETOOTH:
    class _CBDelegate(NSObject):
        """Combined CBCentralManager and CBPeripheral delegate."""

        def initWithOwner_(self, owner):
            self = objc.super(_CBDelegate, self).init()
            if self is None:
                return None
            self._owner = owner
            return self

        # -- CBCentralManagerDelegate --

        def centralManagerDidUpdateState_(self, central):
            state = central.state()
            if state == 5:  # CBManagerStatePoweredOn
                self._owner._on_powered_on()
            elif state == 4:  # CBManagerStatePoweredOff
                self._owner._dbg("Bluetooth is powered off")
                self._owner._done.set()
            else:
                self._owner._dbg(f"CBManager state: {state}")

        def centralManager_didConnectPeripheral_(self, central, peripheral):
            peripheral.setDelegate_(self)
            self._owner._on_connected(peripheral)

        def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
            self._owner._dbg(f"Connection failed: {error}")
            self._owner._done.set()

        # -- CBPeripheralDelegate --

        def peripheral_didDiscoverServices_(self, peripheral, error):
            if error:
                self._owner._dbg(f"Service discovery error: {error}")
                self._owner._done.set()
                return
            self._owner._on_services_discovered(peripheral)

        def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
            if error:
                self._owner._dbg(f"Characteristic discovery error: {error}")
                self._owner._done.set()
                return
            self._owner._on_characteristics_discovered(peripheral, service)

        def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, characteristic, error):
            if error:
                self._owner._dbg(f"Characteristic read error: {error}")
                self._owner._done.set()
                return
            self._owner._on_characteristic_read(peripheral, characteristic)


def read_razer_battery_ble(timeout_s: float = 5.0, debug: bool = False) -> Optional[int]:
    """
    Convenience function to read Razer mouse battery via BLE.

    Returns battery percentage (0-100) or None if unavailable.
    """
    if not HAS_COREBLUETOOTH:
        return None
    try:
        reader = BLERazerBattery(debug=debug)
        return reader.read_battery(timeout_s=timeout_s)
    except Exception:
        if debug:
            import traceback
            traceback.print_exc()
        return None
