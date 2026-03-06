#!/usr/bin/env python3
"""
BLE DPI Write Probe for Razer Mice

Systematically probes the Razer vendor GATT service to reverse-engineer
the BLE protocol for writing DPI values to Razer mice.

Uses CoreBluetooth directly (not bleak) because macOS hides paired BLE
HID devices from BLE scans, and bleak can't connect to them.

Usage:
    python ble_dpi_probe.py                  # Run all probes
    python ble_dpi_probe.py --probe init     # Only try init sequence
    python ble_dpi_probe.py --probe compact  # Only try compact USB format
    python ble_dpi_probe.py --send "13 0a 00 00 10 03 00 00"  # Send arbitrary hex
"""

import argparse
import sys
import time
from typing import Optional, List

try:
    import objc
    from CoreBluetooth import (
        CBCentralManager,
        CBUUID,
    )
    from Foundation import NSRunLoop, NSDate, NSObject
except ImportError:
    print("ERROR: pyobjc-framework-CoreBluetooth required")
    print("  pip install pyobjc-framework-CoreBluetooth")
    sys.exit(1)

# --- UUIDs ---
RAZER_VENDOR_SERVICE = "52401523-F97C-7F90-0E7F-6C6F4E36DB1C"
RAZER_VENDOR_WRITE_CHAR = "52401524-F97C-7F90-0E7F-6C6F4E36DB1C"
RAZER_VENDOR_NOTIFY1_CHAR = "52401525-F97C-7F90-0E7F-6C6F4E36DB1C"
RAZER_VENDOR_NOTIFY2_CHAR = "52401526-F97C-7F90-0E7F-6C6F4E36DB1C"

BATTERY_SERVICE_UUID = "180F"
BATTERY_LEVEL_CHAR_UUID = "2A19"
HID_SERVICE_UUID = "1812"

RAZER_NAME_KEYWORDS = ['razer', 'basilisk', 'bsk', 'deathadder', 'viper']


class BLEProbe:
    """CoreBluetooth-based BLE probe for Razer vendor GATT service."""

    def __init__(self, probes: List[str], custom_hex: Optional[str] = None):
        self.probes = probes
        self.custom_hex = custom_hex
        self.notifications = []
        self.peripheral = None
        self.write_char = None
        self.notify1_char = None
        self.notify2_char = None
        self.battery_char = None
        self.manager = None
        self.phase = "discovery"  # discovery -> connecting -> services -> chars -> probing -> done
        self.services_to_discover = []
        self.chars_pending = 0
        self.probe_queue = []
        self.done = False

    def run(self, timeout_s: float = 120.0):
        """Run the probe on the main thread's NSRunLoop."""
        delegate = _ProbeDelegate.alloc().initWithOwner_(self)
        self.manager = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)

        deadline = time.time() + timeout_s
        while not self.done and time.time() < deadline:
            NSRunLoop.currentRunLoop().runUntilDate_(
                NSDate.dateWithTimeIntervalSinceNow_(0.1)
            )

        if self.peripheral and self.manager:
            try:
                self.manager.cancelPeripheralConnection_(self.peripheral)
            except Exception:
                pass

        # Summary
        print(f"\n{'=' * 60}")
        print(f"SUMMARY: {len(self.notifications)} notification(s) received")
        for ts, name, data in self.notifications:
            print(f"  [{ts}] {name}: {data.hex()}")
            self._decode_notification(data)

    def _decode_notification(self, data: bytes):
        """Try to decode notification data."""
        if len(data) >= 7 and data[0] == 0x05 and data[2] == 0x02:
            dpi_x = (data[3] << 8) | data[4]
            dpi_y = (data[5] << 8) | data[6]
            print(f"         -> DPI report: {dpi_x} x {dpi_y}")
        if len(data) >= 2:
            # Check for status-like responses
            status_names = {0x00: "new", 0x01: "busy", 0x02: "success",
                           0x03: "failure", 0x04: "timeout", 0x05: "not_supported"}
            if data[0] in status_names:
                print(f"         -> Possible status: {status_names[data[0]]}")

    def on_powered_on(self):
        """Find and connect to Razer BLE device."""
        print("Bluetooth powered on, searching for paired Razer device...")
        battery_uuid = CBUUID.UUIDWithString_(BATTERY_SERVICE_UUID)
        peripherals = self.manager.retrieveConnectedPeripheralsWithServices_([battery_uuid])
        print(f"  Found {len(peripherals)} peripheral(s) with Battery Service")

        for p in peripherals:
            name = p.name() or ""
            print(f"    {name} ({p.identifier()})")
            if any(kw in name.lower() for kw in RAZER_NAME_KEYWORDS):
                print(f"\n  -> Connecting to: {name}")
                self.peripheral = p
                self.phase = "connecting"
                self.manager.connectPeripheral_options_(p, None)
                return

        print("\nNo Razer BLE device found.")
        self.done = True

    def on_connected(self, peripheral):
        """Discover services on connected peripheral."""
        print(f"Connected to {peripheral.name()}")
        self.phase = "services"
        # Discover vendor service + battery service
        vendor_uuid = CBUUID.UUIDWithString_(RAZER_VENDOR_SERVICE)
        battery_uuid = CBUUID.UUIDWithString_(BATTERY_SERVICE_UUID)
        peripheral.discoverServices_([vendor_uuid, battery_uuid])

    def on_services(self, peripheral):
        """Handle discovered services, discover characteristics."""
        self.phase = "chars"
        self.chars_pending = 0

        for service in peripheral.services() or []:
            svc_uuid = service.UUID().UUIDString().upper()
            print(f"  Service: {svc_uuid}")

            if RAZER_VENDOR_SERVICE.upper() in svc_uuid:
                # Discover all characteristics of vendor service
                self.chars_pending += 1
                peripheral.discoverCharacteristics_forService_(None, service)
            elif BATTERY_SERVICE_UUID.upper() in svc_uuid or "180F" in svc_uuid:
                self.chars_pending += 1
                char_uuid = CBUUID.UUIDWithString_(BATTERY_LEVEL_CHAR_UUID)
                peripheral.discoverCharacteristics_forService_([char_uuid], service)

        if self.chars_pending == 0:
            print("  No relevant services found!")
            self.done = True

    def on_characteristics(self, peripheral, service):
        """Handle discovered characteristics."""
        svc_uuid = service.UUID().UUIDString().upper()
        for char in service.characteristics() or []:
            char_uuid = char.UUID().UUIDString().upper()
            props = []
            prop_val = char.properties()
            if prop_val & 0x02:
                props.append("read")
            if prop_val & 0x04:
                props.append("write-no-resp")
            if prop_val & 0x08:
                props.append("write")
            if prop_val & 0x10:
                props.append("notify")
            if prop_val & 0x20:
                props.append("indicate")
            props_str = ", ".join(props)
            print(f"    Char: {char_uuid}  [{props_str}]")

            if RAZER_VENDOR_WRITE_CHAR.upper() in char_uuid:
                self.write_char = char
                print(f"      -> WRITE characteristic")
            elif RAZER_VENDOR_NOTIFY1_CHAR.upper() in char_uuid:
                self.notify1_char = char
                print(f"      -> NOTIFY-1 characteristic")
            elif RAZER_VENDOR_NOTIFY2_CHAR.upper() in char_uuid:
                self.notify2_char = char
                print(f"      -> NOTIFY-2 characteristic")
            elif BATTERY_LEVEL_CHAR_UUID.upper() in char_uuid:
                self.battery_char = char
                print(f"      -> Battery Level characteristic")

        self.chars_pending -= 1
        if self.chars_pending <= 0:
            self._start_probing(peripheral)

    def _start_probing(self, peripheral):
        """Subscribe to notifications and begin probe sequence."""
        self.phase = "probing"

        # Read battery first
        if self.battery_char:
            print(f"\n  Reading battery level...")
            peripheral.readValueForCharacteristic_(self.battery_char)

        # Subscribe to notifications
        if self.notify1_char:
            print(f"  Subscribing to notify-1...")
            peripheral.setNotifyValue_forCharacteristic_(True, self.notify1_char)
        if self.notify2_char:
            print(f"  Subscribing to notify-2...")
            peripheral.setNotifyValue_forCharacteristic_(True, self.notify2_char)

        if not self.write_char:
            print("\n  ERROR: No write characteristic found!")
            self.done = True
            return

        # Build probe queue
        self._build_probe_queue()

        # Wait 2s for unsolicited notifications, then start probes
        print(f"\n  Waiting 2s for unsolicited notifications...")
        self._schedule_probes(peripheral, delay=2.0)

    def _schedule_probes(self, peripheral, delay: float):
        """Schedule probe execution after a delay."""
        self._probe_start_time = time.time() + delay
        self._probe_index = 0
        self._probing_peripheral = peripheral

    def tick_probes(self):
        """Called from the run loop to execute probes one at a time."""
        if self.phase != "probing":
            return
        if not hasattr(self, '_probe_start_time'):
            return
        if time.time() < self._probe_start_time:
            return

        if self._probe_index >= len(self.probe_queue):
            # All probes done, wait for final responses
            if not hasattr(self, '_final_wait_start'):
                print(f"\n  All probes sent. Waiting 3s for final responses...")
                self._final_wait_start = time.time()
            elif time.time() - self._final_wait_start > 3.0:
                self.done = True
            return

        label, data = self.probe_queue[self._probe_index]
        self._probe_index += 1
        hex_str = data.hex()
        print(f"\n  >> WRITE ({label}): {hex_str} ({len(data)} bytes)")

        try:
            # Write with response
            self._probing_peripheral.writeValue_forCharacteristic_type_(
                data, self.write_char, 0  # 0 = CBCharacteristicWriteWithResponse
            )
            print(f"     Sent (with response)")
        except Exception as e:
            try:
                # Fall back to write without response
                self._probing_peripheral.writeValue_forCharacteristic_type_(
                    data, self.write_char, 1  # 1 = CBCharacteristicWriteWithoutResponse
                )
                print(f"     Sent (without response)")
            except Exception as e2:
                print(f"     FAILED: {e} / {e2}")

        # Wait 0.5s between probes
        self._probe_start_time = time.time() + 0.5

    def on_notification(self, peripheral, characteristic):
        """Handle incoming notification."""
        char_uuid = characteristic.UUID().UUIDString().upper()
        value = characteristic.value()
        if value is None:
            return

        data = bytes(value)
        ts = time.strftime("%H:%M:%S")

        name = "notify1" if RAZER_VENDOR_NOTIFY1_CHAR.upper() in char_uuid else \
               "notify2" if RAZER_VENDOR_NOTIFY2_CHAR.upper() in char_uuid else \
               char_uuid

        self.notifications.append((ts, name, data))
        print(f"  [{ts}] NOTIFY {name}: {data.hex()} ({len(data)} bytes)")
        self._decode_notification(data)

    def on_write_response(self, peripheral, characteristic, error):
        """Handle write response."""
        if error:
            print(f"     Write response error: {error}")
        else:
            char_uuid = characteristic.UUID().UUIDString().upper()[-4:]
            print(f"     Write response OK (char ...{char_uuid})")

    def on_read_value(self, peripheral, characteristic):
        """Handle read value response."""
        char_uuid = characteristic.UUID().UUIDString().upper()
        value = characteristic.value()
        if value is None:
            return

        data = bytes(value)
        if BATTERY_LEVEL_CHAR_UUID.upper() in char_uuid:
            print(f"  Battery Level: {data[0]}%")
        else:
            print(f"  Read {char_uuid}: {data.hex()}")

    def _build_probe_queue(self):
        """Build the list of (label, bytes) probes to send."""
        self.probe_queue = []
        target_dpi = 800
        dpi_h = (target_dpi >> 8) & 0xFF
        dpi_l = target_dpi & 0xFF

        if self.custom_hex:
            hex_clean = self.custom_hex.replace(" ", "").replace("0x", "")
            self.probe_queue.append(("custom", bytes.fromhex(hex_clean)))

        probes = self.probes

        if "all" in probes or "init" in probes:
            self.probe_queue.extend(self._probes_init())

        if "all" in probes or "compact" in probes:
            self.probe_queue.extend(self._probes_compact(dpi_h, dpi_l))

        if "all" in probes or "raw" in probes:
            self.probe_queue.extend(self._probes_raw(dpi_h, dpi_l))

        if "all" in probes or "chunked" in probes:
            self.probe_queue.extend(self._probes_chunked(dpi_h, dpi_l))

        if "all" in probes or "class" in probes:
            self.probe_queue.extend(self._probes_class_scan())

        print(f"\n  Queued {len(self.probe_queue)} probe commands")

    def _probes_init(self):
        """Keyboard-style init sequence probes."""
        probes = []
        probes.append(("[INIT] keyboard init 13 0a...", bytes.fromhex("130a000010030000")))
        probes.append(("[INIT] static white lighting", bytes.fromhex("01000001ffffff000000")))
        for fb in [0x04, 0x07, 0x0F, 0x14, 0x15]:
            probes.append((f"[INIT] variant first=0x{fb:02x}", bytes([fb, 0x0a, 0x00, 0x00, 0x10, 0x03, 0x00, 0x00])))
        return probes

    def _probes_compact(self, dpi_h, dpi_l):
        """Compact USB protocol variant probes."""
        probes = []
        # class+id+args
        probes.append(("[COMPACT] class+id+args",
                       bytes([0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # txn+class+id+args
        probes.append(("[COMPACT] txn=1F+class+id+args",
                       bytes([0x1F, 0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # size+class+id+args
        probes.append(("[COMPACT] size+class+id+args",
                       bytes([0x07, 0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # status+txn+size+class+id+args
        probes.append(("[COMPACT] status+txn+size+class+id+args",
                       bytes([0x00, 0x1F, 0x07, 0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # VARSTORE
        probes.append(("[COMPACT] VARSTORE class+id+args",
                       bytes([0x04, 0x05, 0x01, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # 0x13 header
        probes.append(("[COMPACT] 0x13 hdr+DPI",
                       bytes([0x13, 0x07, 0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l])))
        # txn=3F
        probes.append(("[COMPACT] txn=3F",
                       bytes([0x3F, 0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # txn=FF
        probes.append(("[COMPACT] txn=FF",
                       bytes([0xFF, 0x04, 0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])))
        # GET DPI (to see if we get any response)
        probes.append(("[COMPACT] GET DPI class+id",
                       bytes([0x04, 0x85, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])))
        probes.append(("[COMPACT] txn+GET DPI",
                       bytes([0x1F, 0x04, 0x85, 0x07, 0x00])))
        return probes

    def _probes_raw(self, dpi_h, dpi_l):
        """Raw byte pattern probes."""
        return [
            ("[RAW] 2-byte DPI", bytes([dpi_h, dpi_l])),
            ("[RAW] 4-byte DPI X+Y", bytes([dpi_h, dpi_l, dpi_h, dpi_l])),
            ("[RAW] 0x00+DPI", bytes([0x00, dpi_h, dpi_l])),
            ("[RAW] 0x01+DPI", bytes([0x01, dpi_h, dpi_l])),
            ("[RAW] 0x05+DPI X+Y", bytes([0x05, dpi_h, dpi_l, dpi_h, dpi_l])),
            ("[RAW] 0x05 0x02+DPI", bytes([0x05, 0x02, dpi_h, dpi_l, dpi_h, dpi_l])),
            ("[RAW] init-style+DPI", bytes([0x13, 0x04, 0x00, 0x00, dpi_h, dpi_l, 0x00, 0x00])),
            ("[RAW] SET id+store+DPI", bytes([0x05, 0x00, dpi_h, dpi_l, dpi_h, dpi_l, 0x00, 0x00])),
        ]

    def _probes_chunked(self, dpi_h, dpi_l):
        """Full 90-byte USB protocol probes."""
        report = bytearray(90)
        report[0] = 0x00
        report[1] = 0x1F
        report[5] = 0x07
        report[6] = 0x04
        report[7] = 0x05
        report[8] = 0x00
        report[9] = dpi_h
        report[10] = dpi_l
        report[11] = dpi_h
        report[12] = dpi_l
        crc = 0
        for i in range(2, 88):
            crc ^= report[i]
        report[88] = crc

        probes = []
        probes.append(("[90BYTE] full report", bytes(report)))
        probes.append(("[90BYTE] first 20 bytes", bytes(report[:20])))
        probes.append(("[90BYTE] bytes [5:15] meaningful", bytes(report[5:15])))
        # Also try a GET DPI as full 90-byte
        get_report = bytearray(90)
        get_report[0] = 0x00
        get_report[1] = 0x1F
        get_report[5] = 0x07
        get_report[6] = 0x04
        get_report[7] = 0x85
        get_report[8] = 0x00
        crc = 0
        for i in range(2, 88):
            crc ^= get_report[i]
        get_report[88] = crc
        probes.append(("[90BYTE] full GET DPI report", bytes(get_report)))
        return probes

    def _probes_class_scan(self):
        """Try various GET commands to find any that produce a response."""
        probes = []
        for cls, cid, sz, label in [
            (0x00, 0x85, 0x01, "poll rate"),
            (0x00, 0x81, 0x04, "firmware"),
            (0x04, 0x85, 0x07, "DPI"),
            (0x07, 0x80, 0x02, "battery"),
        ]:
            probes.append((f"[SCAN] compact GET {label}", bytes([cls, cid, sz])))
            probes.append((f"[SCAN] txn+size+GET {label}", bytes([0x1F, sz, cls, cid])))
        return probes


class _ProbeDelegate(NSObject):
    """CoreBluetooth delegate for probe operations."""

    def initWithOwner_(self, owner):
        self = objc.super(_ProbeDelegate, self).init()
        if self is None:
            return None
        self._owner = owner
        return self

    # --- CBCentralManagerDelegate ---

    def centralManagerDidUpdateState_(self, central):
        state = central.state()
        if state == 5:  # PoweredOn
            self._owner.on_powered_on()
        else:
            print(f"Bluetooth state: {state} (not ready)")
            if state in (1, 2, 3):  # Unsupported, Unauthorized, PoweredOff
                self._owner.done = True

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        peripheral.setDelegate_(self)
        self._owner.on_connected(peripheral)

    def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
        print(f"Connection failed: {error}")
        self._owner.done = True

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        print(f"Disconnected: {error}")
        self._owner.done = True

    # --- CBPeripheralDelegate ---

    def peripheral_didDiscoverServices_(self, peripheral, error):
        if error:
            print(f"Service discovery error: {error}")
            self._owner.done = True
            return
        self._owner.on_services(peripheral)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        if error:
            print(f"Characteristic discovery error: {error}")
            self._owner.done = True
            return
        self._owner.on_characteristics(peripheral, service)

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, characteristic, error):
        if error:
            char_uuid = characteristic.UUID().UUIDString().upper()[-4:]
            print(f"  Read error (char ...{char_uuid}): {error}")
            return
        # Check if it's a notification or a read response
        if characteristic.isNotifying() if hasattr(characteristic, 'isNotifying') else False:
            self._owner.on_notification(peripheral, characteristic)
        else:
            # Could be either - check if it's one of the notify chars
            char_uuid = characteristic.UUID().UUIDString().upper()
            if RAZER_VENDOR_NOTIFY1_CHAR.upper() in char_uuid or \
               RAZER_VENDOR_NOTIFY2_CHAR.upper() in char_uuid:
                self._owner.on_notification(peripheral, characteristic)
            else:
                self._owner.on_read_value(peripheral, characteristic)

    def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, characteristic, error):
        self._owner.on_write_response(peripheral, characteristic, error)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, peripheral, characteristic, error):
        char_uuid = characteristic.UUID().UUIDString().upper()[-4:]
        if error:
            print(f"  Notify subscribe error (char ...{char_uuid}): {error}")
        else:
            notifying = characteristic.isNotifying() if hasattr(characteristic, 'isNotifying') else "?"
            print(f"  Notify state updated (char ...{char_uuid}): notifying={notifying}")


def main():
    parser = argparse.ArgumentParser(
        description="Probe Razer BLE vendor service for DPI write protocol",
    )
    parser.add_argument('--probe', type=str, default='all',
                        choices=['all', 'init', 'compact', 'raw', 'chunked', 'class'],
                        help='Which probe(s) to run (default: all)')
    parser.add_argument('--send', type=str, metavar='HEX',
                        help='Send arbitrary hex bytes (e.g., "13 0a 00 00 10 03 00 00")')
    args = parser.parse_args()

    print("=" * 60)
    print("  Razer BLE DPI Write Probe")
    print("=" * 60)

    probes = [args.probe] if args.probe != 'all' else ['all']
    probe = BLEProbe(probes, custom_hex=args.send)

    # Override the run loop to also tick probes
    delegate = _ProbeDelegate.alloc().initWithOwner_(probe)
    probe.manager = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)

    deadline = time.time() + 120.0
    while not probe.done and time.time() < deadline:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )
        probe.tick_probes()

    if probe.peripheral and probe.manager:
        try:
            probe.manager.cancelPeripheralConnection_(probe.peripheral)
        except Exception:
            pass

    # Summary
    print(f"\n{'=' * 60}")
    print(f"SUMMARY: {len(probe.notifications)} notification(s) received")
    for ts, name, data in probe.notifications:
        print(f"  [{ts}] {name}: {data.hex()}")
        probe._decode_notification(data)

    return 0 if probe.notifications else 1


if __name__ == "__main__":
    sys.exit(main())
