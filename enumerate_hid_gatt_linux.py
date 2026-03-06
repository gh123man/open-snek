#!/usr/bin/env python3
"""
BLE HID GATT Enumerator for Razer Mouse - Linux (Steam Deck compatible)

Enumerates ALL GATT characteristics within the BLE HID service (0x1812)
to find Feature/Output Report characteristics used for Razer's config protocol.

Setup (Steam Deck):
  sudo steamos-readonly disable
  sudo pacman -S --needed python python-pip bluez bluez-utils
  sudo steamos-readonly enable
  python3 -m venv ~/venv && source ~/venv/bin/activate
  pip install bleak
  python3 enumerate_hid_gatt_linux.py

Setup (other Linux):
  pip install bleak
  python3 enumerate_hid_gatt_linux.py

If the mouse is already paired, the script will find it automatically.
If not, pair it first: bluetoothctl -> scan on -> pair XX:XX -> trust XX:XX -> connect XX:XX
"""

import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ─── Check dependencies ─────────────────────────────────────────────────────

try:
    from bleak import BleakClient, BleakScanner, BleakError
except ImportError:
    print("ERROR: bleak not installed.")
    print("  pip install bleak")
    print("  (On Steam Deck: python3 -m venv ~/venv && source ~/venv/bin/activate && pip install bleak)")
    sys.exit(1)

# ─── Constants ───────────────────────────────────────────────────────────────

RAZER_NAMES = ["bsk v3 x", "basilisk", "razer"]
RAZER_BT_VID = 0x068E

# Standard BLE UUIDs
HID_SERVICE         = "00001812-0000-1000-8000-00805f9b34fb"
BATTERY_SERVICE     = "0000180f-0000-1000-8000-00805f9b34fb"
REPORT_MAP_CHAR     = "00002a4b-0000-1000-8000-00805f9b34fb"
REPORT_CHAR         = "00002a4d-0000-1000-8000-00805f9b34fb"
HID_INFO_CHAR       = "00002a4a-0000-1000-8000-00805f9b34fb"
HID_CTRL_CHAR       = "00002a4c-0000-1000-8000-00805f9b34fb"
PROTO_MODE_CHAR     = "00002a4e-0000-1000-8000-00805f9b34fb"
REPORT_REF_DESC     = "00002908-0000-1000-8000-00805f9b34fb"
CCCD_DESC           = "00002902-0000-1000-8000-00805f9b34fb"

REPORT_TYPES = {1: "Input", 2: "Output", 3: "Feature"}

CHAR_NAMES = {
    REPORT_MAP_CHAR: "Report Map",
    REPORT_CHAR: "Report",
    HID_INFO_CHAR: "HID Information",
    HID_CTRL_CHAR: "HID Control Point",
    PROTO_MODE_CHAR: "Protocol Mode",
    "00002a19-0000-1000-8000-00805f9b34fb": "Battery Level",
    "00002a29-0000-1000-8000-00805f9b34fb": "Manufacturer Name",
    "00002a50-0000-1000-8000-00805f9b34fb": "PnP ID",
    "52401524-f97c-7f90-0e7f-6c6f4e36db1c": "Razer Write",
    "52401525-f97c-7f90-0e7f-6c6f4e36db1c": "Razer Notify 1",
    "52401526-f97c-7f90-0e7f-6c6f4e36db1c": "Razer Notify 2",
}

OUTPUT_FILE = "gatt_enumeration_results.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────

def log(msg, level="INFO"):
    print(f"[{level}] {msg}")

def is_razer_device(name):
    if not name:
        return False
    name_lower = name.lower()
    return any(kw in name_lower for kw in RAZER_NAMES)

def build_razer_cmd(tx_id, cmd_class, cmd_id, data_size=0, data=None):
    """Build a 90-byte Razer HID feature report."""
    buf = bytearray(90)
    buf[0] = 0x00
    buf[1] = tx_id
    buf[2] = 0x00
    buf[3] = 0x00
    buf[4] = data_size
    buf[5] = cmd_class
    buf[6] = cmd_id
    if data:
        for i, b in enumerate(data):
            if 7 + i < 88:
                buf[7 + i] = b
    crc = 0
    for i in range(2, 88):
        crc ^= buf[i]
    buf[88] = crc
    return bytes(buf)

def check_bluetooth_service():
    """Check if BlueZ is running."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "bluetooth"],
            capture_output=True, text=True, timeout=5
        )
        if result.stdout.strip() != "active":
            log("Bluetooth service not running. Starting it...", "WARN")
            subprocess.run(["sudo", "systemctl", "start", "bluetooth"], timeout=10)
            time.sleep(2)
            return True
        return True
    except Exception as e:
        log(f"Could not check bluetooth service: {e}", "WARN")
        return True  # Proceed anyway

# ─── Main Logic ──────────────────────────────────────────────────────────────

async def find_razer_device():
    """Find the Razer mouse, either already connected or by scanning."""
    log("Looking for paired Razer devices...")

    # Strategy 1: Check already-paired devices via bleak
    try:
        devices = await BleakScanner.discover(timeout=5.0)
        for d in devices:
            if is_razer_device(d.name):
                log(f"Found via scan: {d.name} ({d.address})")
                return d.address
    except Exception as e:
        log(f"Scan failed: {e}", "WARN")

    # Strategy 2: Check bluetoothctl for paired devices
    log("Scan didn't find device. Checking paired devices via bluetoothctl...")
    try:
        result = subprocess.run(
            ["bluetoothctl", "devices", "Paired"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split("\n"):
            # Format: "Device XX:XX:XX:XX:XX:XX Name"
            parts = line.strip().split(" ", 2)
            if len(parts) >= 3 and is_razer_device(parts[2]):
                addr = parts[1]
                log(f"Found paired: {parts[2]} ({addr})")
                return addr
    except Exception as e:
        log(f"bluetoothctl check failed: {e}", "WARN")

    # Strategy 3: Check all bluetoothctl devices
    try:
        result = subprocess.run(
            ["bluetoothctl", "devices"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split("\n"):
            parts = line.strip().split(" ", 2)
            if len(parts) >= 3 and is_razer_device(parts[2]):
                addr = parts[1]
                log(f"Found known: {parts[2]} ({addr})")
                return addr
    except Exception as e:
        log(f"bluetoothctl devices failed: {e}", "WARN")

    return None


async def clear_gatt_cache(address):
    """Clear BlueZ GATT cache for the device to force fresh discovery."""
    log("Clearing BlueZ GATT cache for fresh discovery...")
    addr_path = address.upper().replace(":", "_")

    # Find adapter address
    try:
        result = subprocess.run(
            ["bluetoothctl", "show"],
            capture_output=True, text=True, timeout=5
        )
        adapter_addr = None
        for line in result.stdout.split("\n"):
            if "Controller" in line:
                parts = line.strip().split()
                if len(parts) >= 2:
                    adapter_addr = parts[1]
                    break

        if adapter_addr:
            cache_dir = Path(f"/var/lib/bluetooth/{adapter_addr}/{address.upper()}/cache")
            if cache_dir.exists():
                log(f"  Removing cache: {cache_dir}")
                try:
                    subprocess.run(["sudo", "rm", "-rf", str(cache_dir)], timeout=5)
                    # Restart bluetooth to pick up the change
                    subprocess.run(["sudo", "systemctl", "restart", "bluetooth"], timeout=10)
                    time.sleep(3)
                    log("  Cache cleared, bluetooth restarted")
                except Exception as e:
                    log(f"  Cache clear failed (non-fatal): {e}", "WARN")
            else:
                log(f"  No cache found at {cache_dir}")
    except Exception as e:
        log(f"  Cache clear skipped: {e}", "WARN")


async def enumerate_gatt(address):
    """Connect and enumerate all GATT services/characteristics."""
    results = {
        "device_address": address,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "services": [],
        "hid_reports": {
            "input": [],
            "output": [],
            "feature": [],
        },
        "report_map": None,
        "razer_test_results": [],
    }

    log(f"Connecting to {address}...")

    # Retry connection up to 3 times
    client = BleakClient(address, timeout=15.0)
    for attempt in range(3):
        try:
            await client.connect()
            break
        except Exception as e:
            if attempt < 2:
                log(f"Connection attempt {attempt+1} failed: {e}. Retrying in 3s...", "WARN")
                await asyncio.sleep(3)
            else:
                log(f"All connection attempts failed: {e}", "ERROR")
                return results

    if not client.is_connected:
        log("Not connected!", "ERROR")
        return results

    log(f"Connected! MTU: {client.mtu_size}")
    print()

    try:
        # ── Enumerate all services ───────────────────────────────────────
        print("=" * 70)
        print("GATT SERVICE ENUMERATION")
        print("=" * 70)

        for svc in client.services:
            svc_data = {
                "uuid": svc.uuid,
                "handle": svc.handle,
                "description": svc.description,
                "characteristics": [],
            }

            is_hid = svc.uuid == HID_SERVICE
            marker = " *** HID SERVICE ***" if is_hid else ""

            print(f"\nService: {svc.uuid} (handle 0x{svc.handle:04X}){marker}")
            print(f"  Description: {svc.description}")

            for char in svc.characteristics:
                char_name = CHAR_NAMES.get(char.uuid, char.description or "")
                props = list(char.properties)

                char_data = {
                    "uuid": char.uuid,
                    "handle": char.handle,
                    "name": char_name,
                    "properties": props,
                    "descriptors": [],
                    "report_id": None,
                    "report_type": None,
                    "value": None,
                }

                print(f"  Char: {char.uuid} (handle 0x{char.handle:04X}) [{', '.join(props)}]")
                if char_name:
                    print(f"    Name: {char_name}")

                # Read descriptors
                for desc in char.descriptors:
                    desc_data = {
                        "uuid": desc.uuid,
                        "handle": desc.handle,
                        "value": None,
                    }

                    if str(desc.uuid) == CCCD_DESC:
                        # Skip CCCD, not interesting for our purpose
                        continue

                    try:
                        val = await client.read_gatt_descriptor(desc.handle)
                        desc_data["value"] = val.hex()

                        if str(desc.uuid) == REPORT_REF_DESC and len(val) >= 2:
                            report_id = val[0]
                            report_type = val[1]
                            type_name = REPORT_TYPES.get(report_type, f"Unknown({report_type})")

                            char_data["report_id"] = report_id
                            char_data["report_type"] = report_type
                            char_data["report_type_name"] = type_name

                            print(f"    Report Reference: ID={report_id}, Type={type_name}")

                            entry = {
                                "report_id": report_id,
                                "char_uuid": char.uuid,
                                "char_handle": char.handle,
                                "properties": props,
                            }

                            if report_type == 1:
                                results["hid_reports"]["input"].append(entry)
                            elif report_type == 2:
                                results["hid_reports"]["output"].append(entry)
                            elif report_type == 3:
                                results["hid_reports"]["feature"].append(entry)
                        else:
                            print(f"    Descriptor {desc.uuid}: {val.hex()}")

                    except Exception as e:
                        print(f"    Descriptor {desc.uuid}: read error ({e})")

                    char_data["descriptors"].append(desc_data)

                # Try reading characteristic value
                if "read" in props:
                    try:
                        val = await client.read_gatt_char(char)
                        char_data["value"] = val.hex()

                        if char.uuid == REPORT_MAP_CHAR:
                            results["report_map"] = val.hex()
                            print(f"    Report Map ({len(val)} bytes):")
                            for i in range(0, len(val), 16):
                                chunk = val[i:i+16]
                                hex_str = " ".join(f"{b:02X}" for b in chunk)
                                print(f"      {i:04X}: {hex_str}")
                        elif char.uuid == HID_INFO_CHAR:
                            print(f"    HID Info: {val.hex()}")
                        elif char.uuid == PROTO_MODE_CHAR:
                            mode = val[0] if val else -1
                            mode_name = {0: "Boot", 1: "Report"}.get(mode, f"Unknown({mode})")
                            print(f"    Protocol Mode: {mode_name} ({mode})")
                        elif len(val) <= 32:
                            print(f"    Value: {val.hex()}")
                        else:
                            print(f"    Value: ({len(val)} bytes) {val[:16].hex()}...")
                    except Exception as e:
                        print(f"    Read error: {e}")

                svc_data["characteristics"].append(char_data)

            results["services"].append(svc_data)

        # ── Summary ──────────────────────────────────────────────────────
        print()
        print("=" * 70)
        print("REPORT SUMMARY")
        print("=" * 70)

        for rtype in ["input", "output", "feature"]:
            reports = results["hid_reports"][rtype]
            print(f"\n{rtype.upper()} Reports ({len(reports)}):")
            if reports:
                for r in reports:
                    print(f"  Report ID {r['report_id']:3d} | Handle 0x{r['char_handle']:04X} | Props: {r['properties']}")
            else:
                print("  (none)")

        # ── Test Razer protocol on Feature Reports ───────────────────────
        feature_reports = results["hid_reports"]["feature"]
        output_reports = results["hid_reports"]["output"]

        test_targets = []
        for r in feature_reports:
            test_targets.append(("Feature", r))
        for r in output_reports:
            test_targets.append(("Output", r))

        if test_targets:
            print()
            print("=" * 70)
            print("TESTING RAZER PROTOCOL")
            print("=" * 70)

            # Safe read-only commands
            test_commands = [
                ("Get Serial", 0x1F, 0x00, 0x82, 0x16, None),
                ("Get Firmware", 0x1F, 0x00, 0x81, 0x00, None),
                ("Get DPI", 0x1F, 0x04, 0x85, 0x01, [0x01]),
                ("Get Battery", 0x1F, 0x07, 0x80, 0x02, None),
            ]

            for rtype_name, report_info in test_targets:
                char_handle = report_info["char_handle"]
                report_id = report_info["report_id"]
                props = report_info["properties"]

                # Find the actual characteristic object
                target_char = None
                for svc in client.services:
                    for c in svc.characteristics:
                        if c.handle == char_handle:
                            target_char = c
                            break

                if not target_char:
                    continue

                print(f"\n  {rtype_name} Report ID {report_id} (handle 0x{char_handle:04X}):")

                can_write = "write" in props or "write-without-response" in props
                can_read = "read" in props

                for cmd_name, tx_id, cmd_class, cmd_id, data_size, data in test_commands:
                    cmd = build_razer_cmd(tx_id, cmd_class, cmd_id, data_size or 0, data)

                    test_result = {
                        "report_type": rtype_name,
                        "report_id": report_id,
                        "handle": char_handle,
                        "command": cmd_name,
                        "write_ok": False,
                        "response": None,
                    }

                    if can_write:
                        print(f"    [{cmd_name}] Writing {len(cmd)} bytes...")
                        try:
                            use_response = "write" in props
                            await client.write_gatt_char(target_char, cmd, response=use_response)
                            test_result["write_ok"] = True
                            print(f"      Write OK!")

                            if can_read:
                                await asyncio.sleep(0.15)
                                try:
                                    resp = await client.read_gatt_char(target_char)
                                    test_result["response"] = resp.hex()
                                    print(f"      Response ({len(resp)} bytes): {resp.hex()}")
                                    if len(resp) >= 7:
                                        status = resp[0]
                                        tx = resp[1]
                                        cls = resp[5]
                                        cid = resp[6]
                                        status_names = {0x00: "New", 0x01: "Busy", 0x02: "OK", 0x03: "Fail", 0x04: "Timeout", 0x05: "Unsupported"}
                                        sname = status_names.get(status, f"0x{status:02X}")
                                        print(f"      Parsed: status={sname}, tx=0x{tx:02X}, class=0x{cls:02X}, cmd=0x{cid:02X}")
                                except Exception as e:
                                    print(f"      Read-back error: {e}")
                        except Exception as e:
                            print(f"      Write error: {e}")
                    else:
                        print(f"    [{cmd_name}] Skipped (not writable)")

                    results["razer_test_results"].append(test_result)

        else:
            print()
            print("=" * 70)
            print("NO FEATURE/OUTPUT REPORTS FOUND")
            print("=" * 70)
            print()
            print("The HID service has no Feature or Output reports.")
            print("This means Razer's driver writes to GATT characteristics")
            print("directly, outside the standard HID report mechanism.")
            print()
            print("Look for any writable characteristics in the HID service")
            print("that are NOT standard HID UUIDs - these would be vendor")
            print("extensions within the HID service.")

            # Check for non-standard characteristics in HID service
            for svc in client.services:
                if svc.uuid == HID_SERVICE:
                    print(f"\nAll characteristics in HID service:")
                    for c in svc.characteristics:
                        standard = c.uuid in [REPORT_CHAR, REPORT_MAP_CHAR, HID_INFO_CHAR,
                                              HID_CTRL_CHAR, PROTO_MODE_CHAR]
                        marker = "" if standard else " *** NON-STANDARD ***"
                        print(f"  {c.uuid} handle=0x{c.handle:04X} [{', '.join(c.properties)}]{marker}")

    except Exception as e:
        log(f"Enumeration error: {e}", "ERROR")
        import traceback
        traceback.print_exc()

    finally:
        if client.is_connected:
            await client.disconnect()

    return results


async def main():
    print("=" * 70)
    print("Razer BLE HID GATT Enumerator")
    print("=" * 70)
    print()

    # Check bluetooth
    check_bluetooth_service()

    # Find device
    address = None

    # Check command-line argument first
    if len(sys.argv) > 1:
        address = sys.argv[1]
        log(f"Using address from command line: {address}")
    else:
        address = await find_razer_device()

    if not address:
        print()
        log("Could not find Razer mouse!", "ERROR")
        print()
        print("Make sure the mouse is:")
        print("  1. Powered on and in BT mode (not USB dongle mode)")
        print("  2. Paired with this machine:")
        print("     bluetoothctl")
        print("     > scan on")
        print("     > pair CE:BF:9B:2A:EF:80")
        print("     > trust CE:BF:9B:2A:EF:80")
        print("     > connect CE:BF:9B:2A:EF:80")
        print()
        print("Then re-run this script, or pass the address directly:")
        print("  python3 enumerate_hid_gatt_linux.py CE:BF:9B:2A:EF:80")
        sys.exit(1)

    print()

    # Optional: clear GATT cache for fresh discovery
    if "--clear-cache" in sys.argv:
        await clear_gatt_cache(address)

    # Enumerate
    results = await enumerate_gatt(address)

    # Save results
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), OUTPUT_FILE)
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print()
    log(f"Results saved to {out_path}")

    # Final summary
    print()
    print("=" * 70)
    print("FINAL SUMMARY")
    print("=" * 70)
    n_svc = len(results["services"])
    n_in = len(results["hid_reports"]["input"])
    n_out = len(results["hid_reports"]["output"])
    n_feat = len(results["hid_reports"]["feature"])
    has_hid = any(s["uuid"] == HID_SERVICE for s in results["services"])
    has_map = results["report_map"] is not None

    print(f"  Services discovered: {n_svc}")
    print(f"  HID Service visible: {'YES' if has_hid else 'NO (still hidden!)'}")
    print(f"  Report Map obtained: {'YES' if has_map else 'NO'}")
    print(f"  Input Reports:       {n_in}")
    print(f"  Output Reports:      {n_out}")
    print(f"  Feature Reports:     {n_feat}")

    if n_feat > 0:
        print()
        print("  *** FEATURE REPORTS FOUND! ***")
        print("  These are the BLE equivalent of USB Feature Reports.")
        print("  Razer's 90-byte protocol likely goes through these.")
    elif n_out > 0:
        print()
        print("  *** OUTPUT REPORTS FOUND! ***")
        print("  Config commands may go through these.")

    if not has_hid:
        print()
        print("  WARNING: HID service was NOT visible.")
        print("  Try: python3 enumerate_hid_gatt_linux.py --clear-cache")
        print("  Or disconnect/re-pair the mouse.")

    tests_ok = [t for t in results["razer_test_results"] if t["write_ok"]]
    if tests_ok:
        print(f"\n  Razer commands accepted: {len(tests_ok)}/{len(results['razer_test_results'])}")

    print()
    print(f"Full results: {out_path}")
    print("Copy this file back for analysis.")


if __name__ == "__main__":
    asyncio.run(main())
