#!/usr/bin/env python3
"""
Explore BLE GATT services on Razer mouse.

This script scans for Bluetooth devices and explores their GATT characteristics,
looking for Razer-specific services that might be used for configuration.
"""

import asyncio
import sys
from bleak import BleakScanner, BleakClient

# Known Razer BLE service UUIDs (these are guesses - need to discover actual ones)
# Standard BLE services
DEVICE_INFO_SERVICE = "0000180a-0000-1000-8000-00805f9b34fb"
BATTERY_SERVICE = "0000180f-0000-1000-8000-00805f9b34fb"
HID_SERVICE = "00001812-0000-1000-8000-00805f9b34fb"


async def scan_for_devices(timeout: float = 10.0):
    """Scan for BLE devices and find Razer ones."""
    print(f"Scanning for BLE devices ({timeout}s)...")
    print("=" * 60)

    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)

    razer_devices = []
    for device, adv_data in devices.values():
        name = device.name or adv_data.local_name or ""
        name_lower = name.lower()

        # Check for Razer devices
        is_razer = any(kw in name_lower for kw in ['razer', 'basilisk', 'bsk', 'deathadder', 'viper'])

        if is_razer:
            razer_devices.append((device, adv_data))
            print(f"\n[RAZER DEVICE FOUND]")
            print(f"  Name: {name}")
            print(f"  Address: {device.address}")
            print(f"  RSSI: {adv_data.rssi} dBm")

            if adv_data.service_uuids:
                print(f"  Advertised Services:")
                for uuid in adv_data.service_uuids:
                    print(f"    - {uuid}")

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
                print(f"\n  Service: {service.uuid}")
                print(f"    Description: {service.description}")

                for char in service.characteristics:
                    props = ", ".join(char.properties)
                    print(f"\n    Characteristic: {char.uuid}")
                    print(f"      Properties: {props}")
                    print(f"      Handle: {char.handle}")

                    # Try to read if readable
                    if "read" in char.properties:
                        try:
                            value = await client.read_gatt_char(char)
                            # Try to decode as string or show as hex
                            try:
                                decoded = value.decode('utf-8')
                                print(f"      Value (str): {decoded}")
                            except:
                                print(f"      Value (hex): {value.hex()}")
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
    # The 90-byte format used in USB
    command = bytearray(90)
    command[0] = 0x00  # Status
    command[1] = 0x1F  # Transaction ID
    command[5] = 0x07  # Data size
    command[6] = 0x04  # Command class (DPI)
    command[7] = 0x85  # Command ID (GET_DPI_XY)
    command[8] = 0x00  # NOSTORE

    # Calculate CRC
    crc = 0
    for i in range(2, 88):
        crc ^= command[i]
    command[88] = crc

    try:
        async with BleakClient(device) as client:
            print(f"Connected: {client.is_connected}")

            # Look for writable characteristics that might accept Razer commands
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

                # Check if there's a notify characteristic we should subscribe to
                has_notify = "notify" in char.properties or "indicate" in char.properties

                if has_notify:
                    # Set up notification handler
                    response_data = []

                    def notification_handler(sender, data):
                        print(f"    Notification received: {data.hex()}")
                        response_data.append(data)

                    try:
                        await client.start_notify(char, notification_handler)
                    except Exception as e:
                        print(f"    Could not start notify: {e}")

                # Try to write the command
                try:
                    # Some devices want shorter commands over BLE
                    # Try both full 90-byte and truncated versions
                    for cmd_len in [90, 64, 32, 20]:
                        truncated = bytes(command[:cmd_len])
                        print(f"    Writing {cmd_len} bytes: {truncated[:16].hex()}...")

                        if "write-without-response" in char.properties:
                            await client.write_gatt_char(char, truncated, response=False)
                        else:
                            await client.write_gatt_char(char, truncated)

                        # Wait for response
                        await asyncio.sleep(0.2)

                        if response_data:
                            print(f"    Got response!")
                            break

                except Exception as e:
                    print(f"    Write error: {type(e).__name__}: {e}")

                if has_notify:
                    try:
                        await client.stop_notify(char)
                    except:
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
        # Create a minimal device object
        devices = await BleakScanner.discover(timeout=5.0, return_adv=True)
        for device, adv_data in devices.values():
            if device.address.lower() == address.lower():
                await explore_device(device)
                await try_write_razer_command(device)
                return

        print(f"Device {address} not found")
        return

    # Scan for devices
    razer_devices = await scan_for_devices()

    if not razer_devices:
        print("\nTo explore a specific device, run:")
        print("  python explore_ble.py <device-address>")
        return

    # Explore each Razer device found
    for device, adv_data in razer_devices:
        await explore_device(device)
        await try_write_razer_command(device)


if __name__ == "__main__":
    asyncio.run(main())
