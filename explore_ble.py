#!/usr/bin/env python3
"""
Explore BLE GATT services on Razer mouse.

This script discovers Razer BLE devices and explores their GATT characteristics.
It uses two discovery methods:
  1. CoreBluetooth retrieveConnectedPeripherals (finds paired HID devices hidden from scans)
  2. Standard BLE scan via bleak (fallback)

Usage:
    python explore_ble.py                    # Auto-discover and explore
    python explore_ble.py <device-address>   # Explore specific device
"""

import asyncio
import sys
import threading
import time
from bleak import BleakScanner, BleakClient

# Standard BLE services
DEVICE_INFO_SERVICE = "0000180a-0000-1000-8000-00805f9b34fb"
BATTERY_SERVICE = "0000180f-0000-1000-8000-00805f9b34fb"
HID_SERVICE = "00001812-0000-1000-8000-00805f9b34fb"

# Razer vendor-specific GATT service (confirmed on Basilisk V3 X HS, BlackWidow V3 Mini)
RAZER_VENDOR_SERVICE = "52401523-f97c-7f90-0e7f-6c6f4e36db1c"
RAZER_VENDOR_WRITE_CHAR = "52401524-f97c-7f90-0e7f-6c6f4e36db1c"
RAZER_VENDOR_NOTIFY1_CHAR = "52401525-f97c-7f90-0e7f-6c6f4e36db1c"
RAZER_VENDOR_NOTIFY2_CHAR = "52401526-f97c-7f90-0e7f-6c6f4e36db1c"

# Known service descriptions
KNOWN_SERVICES = {
    "180f": "Battery Service",
    "1812": "HID Service",
    "180a": "Device Information",
    RAZER_VENDOR_SERVICE: "Razer Vendor Service (lighting/config)",
}

RAZER_NAME_KEYWORDS = ['razer', 'basilisk', 'bsk', 'deathadder', 'viper']


def discover_paired_razer_devices():
    """
    Use CoreBluetooth retrieveConnectedPeripheralsWithServices to find
    paired Razer BLE devices that are hidden from normal BLE scans on macOS.

    Returns list of (name, uuid_string) tuples.
    """
    try:
        import objc
        from CoreBluetooth import CBCentralManager, CBUUID
        from Foundation import NSRunLoop, NSDate, NSObject
    except ImportError:
        return []

    results = []
    done = threading.Event()

    class _Delegate(NSObject):
        def initWithCallback_(self, callback):
            self = objc.super(_Delegate, self).init()
            if self is None:
                return None
            self._callback = callback
            return self

        def centralManagerDidUpdateState_(self, central):
            if central.state() != 5:  # Not PoweredOn
                done.set()
                return

            # Search for peripherals with Battery or HID service
            found = []
            for svc_uuid in ["180F", "1812"]:
                uuid = CBUUID.UUIDWithString_(svc_uuid)
                peripherals = central.retrieveConnectedPeripheralsWithServices_([uuid])
                for p in peripherals:
                    name = p.name() or ""
                    ident = str(p.identifier())
                    if (name, ident) not in [(n, i) for n, i in found]:
                        found.append((name, ident))

            self._callback(found)
            done.set()

    def _run():
        delegate = _Delegate.alloc().initWithCallback_(lambda r: results.extend(r))
        CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
        deadline = time.time() + 5.0
        while not done.is_set() and time.time() < deadline:
            NSRunLoop.currentRunLoop().runUntilDate_(
                NSDate.dateWithTimeIntervalSinceNow_(0.1)
            )

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()
    done.wait(timeout=6.0)

    return results


async def scan_for_devices(timeout: float = 10.0):
    """Scan for BLE devices and find Razer ones."""
    print(f"Scanning for BLE devices ({timeout}s)...")
    print("=" * 60)

    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)

    razer_devices = []
    for device, adv_data in devices.values():
        name = device.name or adv_data.local_name or ""
        name_lower = name.lower()

        is_razer = any(kw in name_lower for kw in RAZER_NAME_KEYWORDS)

        if is_razer:
            razer_devices.append((device, adv_data))
            print(f"\n[RAZER DEVICE FOUND]")
            print(f"  Name: {name}")
            print(f"  Address: {device.address}")
            print(f"  RSSI: {adv_data.rssi} dBm")

            if adv_data.service_uuids:
                print(f"  Advertised Services:")
                for uuid in adv_data.service_uuids:
                    desc = KNOWN_SERVICES.get(uuid.lower().replace("0000", "").split("-")[0], "")
                    suffix = f" ({desc})" if desc else ""
                    print(f"    - {uuid}{suffix}")

            if adv_data.manufacturer_data:
                print(f"  Manufacturer Data:")
                for company_id, data in adv_data.manufacturer_data.items():
                    print(f"    - Company ID: 0x{company_id:04x}, Data: {data.hex()}")

    if not razer_devices:
        print("\nNo Razer devices found in BLE scan.")
        print("\nAll devices found:")
        for device, adv_data in list(devices.values())[:10]:
            name = device.name or adv_data.local_name or "(unnamed)"
            print(f"  {device.address}: {name}")

    return razer_devices


def service_description(uuid_str: str) -> str:
    """Look up a human-readable description for a service UUID."""
    short = uuid_str.lower().replace("0000", "").split("-")[0]
    return KNOWN_SERVICES.get(short, KNOWN_SERVICES.get(uuid_str.lower(), ""))


async def explore_device(device):
    """Connect to a device and explore its GATT services."""
    print(f"\n{'=' * 60}")
    print(f"Connecting to: {device.name} ({device.address})")
    print(f"{'=' * 60}")

    try:
        async with BleakClient(device) as client:
            print(f"Connected: {client.is_connected}")

            print("\nGATT Services:")
            for service in client.services:
                desc = service_description(service.uuid)
                desc_str = f" — {desc}" if desc else ""
                print(f"\n  Service: {service.uuid}{desc_str}")
                print(f"    Description: {service.description}")

                for char in service.characteristics:
                    props = ", ".join(char.properties)
                    print(f"\n    Characteristic: {char.uuid}")
                    print(f"      Properties: {props}")
                    print(f"      Handle: {char.handle}")

                    # Highlight known Razer vendor characteristics
                    char_lower = char.uuid.lower()
                    if char_lower == RAZER_VENDOR_WRITE_CHAR:
                        print(f"      ** Razer vendor WRITE characteristic **")
                    elif char_lower == RAZER_VENDOR_NOTIFY1_CHAR:
                        print(f"      ** Razer vendor NOTIFY-1 characteristic **")
                    elif char_lower == RAZER_VENDOR_NOTIFY2_CHAR:
                        print(f"      ** Razer vendor NOTIFY-2 characteristic **")

                    # Try to read if readable
                    if "read" in char.properties:
                        try:
                            value = await client.read_gatt_char(char)
                            try:
                                decoded = value.decode('utf-8')
                                print(f"      Value (str): {decoded}")
                            except Exception:
                                print(f"      Value (hex): {value.hex()}")
                                # Decode known characteristics
                                if char.uuid.lower().endswith("2a19"):
                                    print(f"      Battery Level: {value[0]}%")
                        except Exception as e:
                            print(f"      Read error: {e}")

                    # List descriptors
                    for desc in char.descriptors:
                        print(f"      Descriptor: {desc.uuid}")
                        try:
                            value = await client.read_gatt_descriptor(desc.handle)
                            print(f"        Value: {value.hex()}")
                        except Exception as e:
                            print(f"        Read error: {e}")

    except Exception as e:
        print(f"Error connecting: {type(e).__name__}: {e}")


async def try_write_razer_command(device):
    """Try to find and write to a Razer-specific characteristic."""
    print(f"\n{'=' * 60}")
    print(f"Attempting Razer protocol over BLE...")
    print(f"{'=' * 60}")

    # Build a simple Razer command (get DPI)
    command = bytearray(90)
    command[0] = 0x00  # Status
    command[1] = 0x1F  # Transaction ID
    command[5] = 0x07  # Data size
    command[6] = 0x04  # Command class (DPI)
    command[7] = 0x85  # Command ID (GET_DPI_XY)
    command[8] = 0x00  # NOSTORE

    crc = 0
    for i in range(2, 88):
        crc ^= command[i]
    command[88] = crc

    try:
        async with BleakClient(device) as client:
            print(f"Connected: {client.is_connected}")

            # Look for writable characteristics
            writable_chars = []
            for service in client.services:
                for char in service.characteristics:
                    if "write" in char.properties or "write-without-response" in char.properties:
                        writable_chars.append((service, char))

            print(f"\nFound {len(writable_chars)} writable characteristics")

            for service, char in writable_chars:
                print(f"\n  Trying: {char.uuid}")
                print(f"    Service: {service.uuid}")
                print(f"    Properties: {', '.join(char.properties)}")

                has_notify = "notify" in char.properties or "indicate" in char.properties

                if has_notify:
                    response_data = []

                    def notification_handler(sender, data):
                        print(f"    Notification received: {data.hex()}")
                        response_data.append(data)

                    try:
                        await client.start_notify(char, notification_handler)
                    except Exception as e:
                        print(f"    Could not start notify: {e}")

                try:
                    for cmd_len in [90, 64, 32, 20]:
                        truncated = bytes(command[:cmd_len])
                        print(f"    Writing {cmd_len} bytes: {truncated[:16].hex()}...")

                        if "write-without-response" in char.properties:
                            await client.write_gatt_char(char, truncated, response=False)
                        else:
                            await client.write_gatt_char(char, truncated)

                        await asyncio.sleep(0.2)

                        if has_notify and response_data:
                            print(f"    Got response!")
                            break

                except Exception as e:
                    print(f"    Write error: {type(e).__name__}: {e}")

                if has_notify:
                    try:
                        await client.stop_notify(char)
                    except Exception:
                        pass

    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")


async def main():
    print("\n" + "=" * 60)
    print("Razer BLE Explorer")
    print("=" * 60)
    print("\nThis tool explores BLE GATT services on your Razer mouse.")
    print("It may help discover how to configure the mouse over Bluetooth.\n")

    # Check if a device address was provided
    if len(sys.argv) > 1:
        address = sys.argv[1]
        print(f"Using provided address: {address}")
        devices = await BleakScanner.discover(timeout=5.0, return_adv=True)
        for device, adv_data in devices.values():
            if device.address.lower() == address.lower():
                await explore_device(device)
                await try_write_razer_command(device)
                return

        print(f"Device {address} not found in scan")
        return

    # Method 1: Try CoreBluetooth retrieveConnectedPeripherals
    # This finds paired BLE HID devices that macOS hides from normal scans.
    print("Checking for paired Razer devices via CoreBluetooth...")
    paired = discover_paired_razer_devices()
    razer_paired = [(name, uuid) for name, uuid in paired
                    if any(kw in name.lower() for kw in RAZER_NAME_KEYWORDS)]

    if razer_paired:
        print(f"\nFound {len(razer_paired)} paired Razer device(s) via CoreBluetooth:")
        for name, uuid in razer_paired:
            print(f"  {name} ({uuid})")
        print("\nThese devices are paired and connected but hidden from BLE scans.")
        print("Use bleak with this UUID to connect, or try BLE scan below.\n")

    # Method 2: Standard BLE scan
    razer_devices = await scan_for_devices()

    if not razer_devices and not razer_paired:
        print("\nNo Razer devices found.")
        print("\nTips:")
        print("  - Make sure the mouse is in Bluetooth mode and connected")
        print("  - Paired HID devices are often hidden from scans on macOS")
        print("  - Try: python explore_ble.py <device-address>")
        return

    # Explore each Razer device found via scan
    for device, adv_data in razer_devices:
        await explore_device(device)
        await try_write_razer_command(device)


if __name__ == "__main__":
    asyncio.run(main())
