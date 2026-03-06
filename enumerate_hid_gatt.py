#!/usr/bin/env python3
"""
Enumerate all GATT characteristics within the BLE HID service (0x1812).
Run on Windows where bleak can access the HID service directly.

Discovers Feature/Output Report characteristics that carry Razer's 90-byte protocol.
"""
import asyncio
import sys

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("Install bleak: pip install bleak")
    sys.exit(1)

# Known Razer BLE mouse address (update if needed)
DEVICE_ADDRESS = "CE:BF:9B:2A:EF:80"

# Standard BLE HID UUIDs
HID_SERVICE        = "00001812-0000-1000-8000-00805f9b34fb"
REPORT_MAP_CHAR    = "00002a4b-0000-1000-8000-00805f9b34fb"  # HID Report Map
REPORT_CHAR        = "00002a4d-0000-1000-8000-00805f9b34fb"  # HID Report
HID_INFO_CHAR      = "00002a4a-0000-1000-8000-00805f9b34fb"  # HID Information
HID_CTRL_CHAR      = "00002a4c-0000-1000-8000-00805f9b34fb"  # HID Control Point
PROTOCOL_MODE_CHAR = "00002a4e-0000-1000-8000-00805f9b34fb"  # Protocol Mode
REPORT_REF_DESC    = "00002908-0000-1000-8000-00805f9b34fb"  # Report Reference descriptor
CCCD_DESC          = "00002902-0000-1000-8000-00805f9b34fb"  # Client Characteristic Config

# Also enumerate vendor service for completeness
VENDOR_SERVICE     = "52401523-f97c-7f90-0e7f-6c6f4e36db1c"

REPORT_TYPES = {1: "Input", 2: "Output", 3: "Feature"}


async def enumerate_device():
    print(f"Connecting to {DEVICE_ADDRESS}...")

    async with BleakClient(DEVICE_ADDRESS) as client:
        print(f"Connected: {client.is_connected}")
        print(f"MTU: {client.mtu_size if hasattr(client, 'mtu_size') else 'unknown'}")
        print()

        # --- Enumerate ALL services ---
        print("=" * 70)
        print("ALL GATT SERVICES")
        print("=" * 70)
        for svc in client.services:
            print(f"\nService: {svc.uuid} (handle {svc.handle})")
            print(f"  Description: {svc.description}")
            for char in svc.characteristics:
                props = ", ".join(char.properties)
                print(f"  Char: {char.uuid} (handle {char.handle}) [{props}]")
                print(f"    Description: {char.description}")

                # Read descriptors
                for desc in char.descriptors:
                    print(f"    Desc: {desc.uuid} (handle {desc.handle})")
                    try:
                        val = await client.read_gatt_descriptor(desc.handle)
                        print(f"      Value: {val.hex()} ({list(val)})")

                        # Decode Report Reference
                        if str(desc.uuid) == REPORT_REF_DESC and len(val) >= 2:
                            report_id = val[0]
                            report_type = REPORT_TYPES.get(val[1], f"Unknown({val[1]})")
                            print(f"      → Report ID: {report_id}, Type: {report_type}")
                    except Exception as e:
                        print(f"      (read error: {e})")

        # --- Focus on HID Service ---
        print()
        print("=" * 70)
        print("HID SERVICE DETAIL")
        print("=" * 70)

        hid_svc = None
        for svc in client.services:
            if svc.uuid == HID_SERVICE:
                hid_svc = svc
                break

        if not hid_svc:
            print("HID service not found!")
            return

        # Read Report Map (HID descriptor)
        report_map_char = None
        feature_reports = []
        output_reports = []
        input_reports = []

        for char in hid_svc.characteristics:
            if char.uuid == REPORT_MAP_CHAR:
                report_map_char = char
            elif char.uuid == REPORT_CHAR:
                # Read Report Reference descriptor
                for desc in char.descriptors:
                    if str(desc.uuid) == REPORT_REF_DESC:
                        try:
                            val = await client.read_gatt_descriptor(desc.handle)
                            if len(val) >= 2:
                                report_id = val[0]
                                report_type = val[1]
                                entry = {
                                    "char": char,
                                    "report_id": report_id,
                                    "report_type": report_type,
                                    "type_name": REPORT_TYPES.get(report_type, f"Unknown({report_type})"),
                                    "props": list(char.properties),
                                }
                                if report_type == 1:
                                    input_reports.append(entry)
                                elif report_type == 2:
                                    output_reports.append(entry)
                                elif report_type == 3:
                                    feature_reports.append(entry)
                        except Exception as e:
                            print(f"  Error reading Report Reference: {e}")

        print(f"\nInput Reports ({len(input_reports)}):")
        for r in input_reports:
            print(f"  Report ID {r['report_id']:3d} | Handle {r['char'].handle:3d} | Props: {r['props']}")

        print(f"\nOutput Reports ({len(output_reports)}):")
        for r in output_reports:
            print(f"  Report ID {r['report_id']:3d} | Handle {r['char'].handle:3d} | Props: {r['props']}")

        print(f"\nFeature Reports ({len(feature_reports)}):")
        for r in feature_reports:
            print(f"  Report ID {r['report_id']:3d} | Handle {r['char'].handle:3d} | Props: {r['props']}")

        # Read Report Map
        if report_map_char:
            print(f"\nReport Map (handle {report_map_char.handle}):")
            try:
                report_map = await client.read_gatt_char(report_map_char)
                print(f"  Size: {len(report_map)} bytes")
                # Print hex dump
                for i in range(0, len(report_map), 16):
                    chunk = report_map[i:i+16]
                    hex_str = " ".join(f"{b:02X}" for b in chunk)
                    print(f"  {i:04X}: {hex_str}")
            except Exception as e:
                print(f"  Error reading Report Map: {e}")

        # --- Try reading Feature Reports ---
        if feature_reports:
            print()
            print("=" * 70)
            print("READING FEATURE REPORTS")
            print("=" * 70)
            for r in feature_reports:
                print(f"\nReport ID {r['report_id']} (handle {r['char'].handle}):")
                try:
                    val = await client.read_gatt_char(r['char'])
                    print(f"  Value ({len(val)} bytes): {val.hex()}")
                except Exception as e:
                    print(f"  Error: {e}")

        # --- Try writing Razer 90-byte protocol to Feature Reports ---
        if feature_reports:
            print()
            print("=" * 70)
            print("TESTING RAZER PROTOCOL ON FEATURE REPORTS")
            print("=" * 70)

            # Build a simple Razer "get serial" command (read-only, safe)
            # Transaction ID 0x1F, status 0x00, remaining 0x00, protocol 0x00
            # data_size 0x16, command_class 0x00, command_id 0x82 (get serial)
            razer_cmd = bytearray(90)
            razer_cmd[0] = 0x00   # status
            razer_cmd[1] = 0x1F   # transaction ID
            razer_cmd[2] = 0x00   # remaining packets
            razer_cmd[3] = 0x00   # protocol type
            razer_cmd[4] = 0x00   # data_size
            razer_cmd[5] = 0x00   # command_class
            razer_cmd[6] = 0x82   # command_id (get serial)
            # Calculate CRC (XOR of bytes 2-87)
            crc = 0
            for i in range(2, 88):
                crc ^= razer_cmd[i]
            razer_cmd[88] = crc
            razer_cmd[89] = 0x00  # reserved

            for r in feature_reports:
                if "write" in r['props'] or "write-without-response" in r['props']:
                    print(f"\n  Writing to Feature Report ID {r['report_id']} (handle {r['char'].handle})...")
                    print(f"  Payload: {razer_cmd[:10].hex()}...{razer_cmd[88:].hex()}")
                    try:
                        await client.write_gatt_char(r['char'], bytes(razer_cmd), response=True)
                        print("  Write OK!")

                        # Try reading back
                        await asyncio.sleep(0.1)
                        try:
                            val = await client.read_gatt_char(r['char'])
                            print(f"  Response ({len(val)} bytes): {val.hex()}")
                            if len(val) >= 7:
                                print(f"    Status: 0x{val[0]:02x}, TxID: 0x{val[1]:02x}, Class: 0x{val[5]:02x}, CmdID: 0x{val[6]:02x}")
                        except Exception as e:
                            print(f"  Read-back error: {e}")
                    except Exception as e:
                        print(f"  Write error: {e}")

        # --- Summary ---
        print()
        print("=" * 70)
        print("SUMMARY")
        print("=" * 70)
        print(f"HID Service handle range: {hid_svc.handle} - ?")
        print(f"Total characteristics in HID service: {len(hid_svc.characteristics)}")
        print(f"Input Reports:   {len(input_reports)}")
        print(f"Output Reports:  {len(output_reports)}")
        print(f"Feature Reports: {len(feature_reports)}")

        if feature_reports:
            print("\n*** FEATURE REPORTS FOUND - Razer protocol likely goes here! ***")
            for r in feature_reports:
                writable = "write" in r['props'] or "write-without-response" in r['props']
                readable = "read" in r['props']
                print(f"  ID {r['report_id']}: {'W' if writable else '-'}{'R' if readable else '-'} handle={r['char'].handle}")
        else:
            print("\nNo Feature Reports found in HID service.")
            print("The Razer driver may inject them at the Windows driver level,")
            print("or commands may go through Output Reports.")

        if output_reports:
            print(f"\nOutput Reports found ({len(output_reports)}) - could also carry commands:")
            for r in output_reports:
                print(f"  ID {r['report_id']}: handle={r['char'].handle} props={r['props']}")


if __name__ == "__main__":
    asyncio.run(enumerate_device())
