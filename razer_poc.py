#!/usr/bin/env python3
"""
Razer Mouse macOS Configuration Tool

Configure DPI, DPI stages, poll rate, and more for Razer mice on macOS.
Supports USB, 2.4GHz dongle, and experimental Bluetooth HID transport.

Usage:
    python razer_poc.py                          # Show current settings
    python razer_poc.py --dpi 1600               # Set current DPI
    python razer_poc.py --stages 400,800,1600    # Set DPI stages
    python razer_poc.py --active-stage 2         # Set active stage (1-5)
    python razer_poc.py --poll-rate 1000         # Set poll rate (125/250/500/1000)
"""

import argparse
import hid
import time
import sys
from typing import Optional, Tuple, List

try:
    from ble_battery import read_razer_battery_ble, HAS_COREBLUETOOTH
except ImportError:
    HAS_COREBLUETOOTH = False

    def read_razer_battery_ble(**kwargs):
        return None

# Constants
USB_VENDOR_ID_RAZER = 0x1532
BT_VENDOR_ID_RAZER = 0x068e
RAZER_USB_REPORT_LEN = 90
RAZER_STATUS_BUSY = 0x01

# Commands
CMD_CLASS_STANDARD = 0x00
CMD_CLASS_DPI = 0x04
CMD_CLASS_MISC = 0x07

CMD_GET_SERIAL = 0x82
CMD_GET_FIRMWARE = 0x81
CMD_GET_DPI_XY = 0x85
CMD_SET_DPI_XY = 0x05
CMD_GET_DPI_STAGES = 0x86
CMD_SET_DPI_STAGES = 0x06
CMD_GET_POLL_RATE = 0x85
CMD_SET_POLL_RATE = 0x05
CMD_GET_BATTERY = 0x80

NOSTORE = 0x00
VARSTORE = 0x01
STATUS_SUCCESS = 0x02
STATUS_NAMES = {
    0x00: "new",
    0x01: "busy",
    0x02: "success",
    0x03: "failure",
    0x04: "timeout",
    0x05: "not_supported",
}

# Device info
KNOWN_MICE = {
    0x00B9: ("Razer Basilisk V3 X HyperSpeed", 18000),
    0x0083: ("Razer Basilisk V3", 26000),
    0x0084: ("Razer Basilisk V3", 26000),
    0x00BA: ("Razer Basilisk V3 X HyperSpeed (BT)", 18000),
}

TRANSACTION_ID_CANDIDATES = {
    # Some Bluetooth firmware variants use a different transaction ID.
    0x00BA: [0x3F, 0x1F, 0xFF],  # Basilisk V3 X HyperSpeed (BT)
}


class RazerMouse:
    """Interface for communicating with a Razer mouse."""

    def __init__(
        self,
        device_path: bytes,
        vendor_id: int,
        product_id: int,
        product_name: str = "",
        debug_hid: bool = False,
    ):
        self.device_path = device_path
        self.vendor_id = vendor_id
        self.product_id = product_id
        self.product_name = product_name
        self.debug_hid = debug_hid
        self.txn_id = 0x1F  # Most modern mice use this
        self.txn_candidates = TRANSACTION_ID_CANDIDATES.get(product_id, [0x1F, 0x3F, 0xFF])
        self.bt_cached_dpi: Optional[Tuple[int, int]] = None

    def _dbg(self, msg: str) -> None:
        if self.debug_hid:
            print(f"[hid-debug] {msg}")

    def _calculate_crc(self, data: bytes) -> int:
        crc = 0
        for i in range(2, 88):
            if i < len(data):
                crc ^= data[i]
        return crc

    def _create_report(self, cmd_class: int, cmd_id: int, data_size: int, args: bytes = b'') -> bytes:
        report = bytearray(RAZER_USB_REPORT_LEN)
        report[0] = 0x00  # Status: new command
        report[1] = self.txn_id
        report[5] = data_size
        report[6] = cmd_class
        report[7] = cmd_id
        for i, b in enumerate(args[:80]):
            report[8 + i] = b
        report[88] = self._calculate_crc(report)
        return bytes(report)

    def _normalize_response(self, data: bytes) -> Optional[bytes]:
        """Normalize HID response payload to a 90-byte Razer report."""
        if not data:
            return None

        # Some backends include report-id as the first byte.
        if len(data) == RAZER_USB_REPORT_LEN + 1:
            return bytes(data[1:])

        if len(data) == RAZER_USB_REPORT_LEN:
            return bytes(data)

        # Defensive fallback: if a larger frame comes back, keep trailing report bytes.
        if len(data) > RAZER_USB_REPORT_LEN:
            return bytes(data[-RAZER_USB_REPORT_LEN:])

        return None

    def _read_response(self, dev: hid.device, attempts: int = 5) -> Optional[bytes]:
        """Read response with retries for slower Bluetooth links."""
        for _ in range(attempts):
            time.sleep(0.03)

            # Try feature report first.
            try:
                feat = dev.get_feature_report(0x00, RAZER_USB_REPORT_LEN + 1)
                normalized = self._normalize_response(bytes(feat) if feat else b"")
                if normalized:
                    self._dbg(f"feature read len={len(normalized)} status=0x{normalized[0]:02x}")
                    if normalized[0] == RAZER_STATUS_BUSY:
                        continue
                    return normalized
            except Exception:
                self._dbg("feature read failed")

            # Fall back to input report read.
            try:
                raw = dev.read(RAZER_USB_REPORT_LEN + 1, timeout_ms=120)
                normalized = self._normalize_response(bytes(raw) if raw else b"")
                if normalized:
                    self._dbg(f"input read len={len(normalized)} status=0x{normalized[0]:02x}")
                    if normalized[0] == RAZER_STATUS_BUSY:
                        continue
                    return normalized
            except Exception:
                self._dbg("input read failed")

        return None

    def _send_command(self, request: bytes) -> Optional[bytes]:
        """Send command and get response over USB/BT HID."""
        dev = None
        try:
            dev = hid.device()
            dev.open_path(self.device_path)
            dev.set_nonblocking(False)
            self._dbg(f"opened path={self.device_path!r} vid=0x{self.vendor_id:04x} pid=0x{self.product_id:04x} txn=0x{self.txn_id:02x}")

            # Try multiple transport variants; Bluetooth HID stacks vary.
            send_attempts = [
                ("feature_with_report_id", lambda: dev.send_feature_report(bytes([0x00]) + request)),
                ("feature_raw", lambda: dev.send_feature_report(request)),
                ("output_with_report_id", lambda: dev.write(bytes([0x00]) + request)),
                ("output_raw", lambda: dev.write(request)),
            ]

            for _, sender in send_attempts:
                name = _
                try:
                    result = sender()
                except Exception as e:
                    self._dbg(f"send {name} failed: {type(e).__name__}: {e}")
                    continue

                self._dbg(f"send {name} result={result}")
                if result and result > 0:
                    response = self._read_response(dev)
                    if response is not None:
                        status_name = STATUS_NAMES.get(response[0], "unknown")
                        self._dbg(f"response status=0x{response[0]:02x} ({status_name})")
                        return response
                else:
                    self._dbg(f"send {name} did not transmit")
        except Exception as e:
            self._dbg(f"open/send sequence failed: {type(e).__name__}: {e}")
        finally:
            if dev is not None:
                try:
                    dev.close()
                except Exception:
                    pass
        return None

    def _read_bt_dpi_passive(self, timeout_s: float = 2.5) -> Optional[Tuple[int, int]]:
        """
        Read DPI from passive Bluetooth input reports.

        On Basilisk V3 X HS over BLE HID, report `05 05 02 xx xx yy yy 00 00`
        has been observed where `xx xx`/`yy yy` are DPI X/Y.
        """
        if self.vendor_id != BT_VENDOR_ID_RAZER:
            return None

        deadline = time.time() + timeout_s
        dev = None
        try:
            dev = hid.device()
            dev.open_path(self.device_path)
            dev.set_nonblocking(True)
            while time.time() < deadline:
                raw = dev.read(64, timeout_ms=120)
                if not raw:
                    continue
                data = bytes(raw)
                if len(data) < 7:
                    continue
                if data[0] != 0x05 or data[1] != 0x05 or data[2] != 0x02:
                    continue

                dpi_x = (data[3] << 8) | data[4]
                dpi_y = (data[5] << 8) | data[6]
                if 100 <= dpi_x <= 30000 and 100 <= dpi_y <= 30000:
                    self.bt_cached_dpi = (dpi_x, dpi_y)
                    self._dbg(f"passive bt dpi={dpi_x}x{dpi_y} packet={data.hex()}")
                    return self.bt_cached_dpi
        except Exception as e:
            self._dbg(f"passive bt dpi read failed: {type(e).__name__}: {e}")
        finally:
            if dev is not None:
                try:
                    dev.close()
                except Exception:
                    pass

        return self.bt_cached_dpi

    def _probe_bt_input_stream(self, timeout_s: float = 2.0) -> bool:
        """Return True if Bluetooth HID input reports are readable."""
        if self.vendor_id != BT_VENDOR_ID_RAZER:
            return False

        deadline = time.time() + timeout_s
        dev = None
        try:
            dev = hid.device()
            dev.open_path(self.device_path)
            dev.set_nonblocking(True)
            while time.time() < deadline:
                raw = dev.read(64, timeout_ms=120)
                if not raw:
                    continue
                data = bytes(raw)
                if len(data) >= 7 and data[0] == 0x05 and data[1] == 0x05 and data[2] == 0x02:
                    dpi_x = (data[3] << 8) | data[4]
                    dpi_y = (data[5] << 8) | data[6]
                    if 100 <= dpi_x <= 30000 and 100 <= dpi_y <= 30000:
                        self.bt_cached_dpi = (dpi_x, dpi_y)
                        self._dbg(f"bt probe cached dpi={dpi_x}x{dpi_y}")
                return True
        except Exception as e:
            self._dbg(f"bt input stream probe failed: {type(e).__name__}: {e}")
        finally:
            if dev is not None:
                try:
                    dev.close()
                except Exception:
                    pass

        return False

    def probe_connection(self) -> bool:
        """Try common txn IDs and command paths to establish working communication."""
        if self.vendor_id == BT_VENDOR_ID_RAZER:
            if self._probe_bt_input_stream(timeout_s=2.0):
                self._dbg("probe bt input stream success")
                return True

        for txn_id in self.txn_candidates:
            self.txn_id = txn_id
            self._dbg(f"probing txn_id=0x{txn_id:02x}")

            if self.get_dpi() is not None:
                self._dbg("probe get_dpi success")
                return True

            if self.get_poll_rate() is not None:
                self._dbg("probe get_poll_rate success")
                return True

            if self.get_battery() is not None:
                self._dbg("probe get_battery success")
                return True

        return False

    # --- DPI ---

    def get_dpi(self) -> Optional[Tuple[int, int]]:
        """Get current DPI (X, Y)."""
        request = self._create_report(CMD_CLASS_DPI, CMD_GET_DPI_XY, 0x07, bytes([NOSTORE]))
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 13:
            dpi_x = (response[9] << 8) | response[10]
            dpi_y = (response[11] << 8) | response[12]
            return (dpi_x, dpi_y)
        # Bluetooth fallback: decode passive HID report stream.
        return self._read_bt_dpi_passive(timeout_s=4.0)

    def set_dpi(self, dpi_x: int, dpi_y: int = None, store: bool = False) -> bool:
        """Set current DPI."""
        if dpi_y is None:
            dpi_y = dpi_x
        dpi_x = max(100, min(30000, dpi_x))
        dpi_y = max(100, min(30000, dpi_y))
        storage = VARSTORE if store else NOSTORE
        args = bytes([storage, (dpi_x >> 8) & 0xFF, dpi_x & 0xFF,
                      (dpi_y >> 8) & 0xFF, dpi_y & 0xFF, 0, 0])
        request = self._create_report(CMD_CLASS_DPI, CMD_SET_DPI_XY, 0x07, args)
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    # --- DPI Stages ---

    def get_dpi_stages(self) -> Optional[Tuple[int, List[int]]]:
        """Get DPI stages. Returns (active_stage_0indexed, [dpi1, dpi2, ...])."""
        request = self._create_report(CMD_CLASS_DPI, CMD_GET_DPI_STAGES, 0x26, bytes([VARSTORE]))
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 12:
            active = response[9]
            count = response[10]
            stages = []
            for i in range(min(count, 5)):
                offset = 11 + (i * 7)
                if offset + 5 <= len(response):
                    dpi_x = (response[offset + 1] << 8) | response[offset + 2]
                    stages.append(dpi_x)
            return (active, stages)
        return None

    def set_dpi_stages(self, stages: List[int], active_stage: int = 0) -> bool:
        """
        Set DPI stages.
        stages: List of DPI values (1-5 stages)
        active_stage: 0-indexed active stage
        """
        count = min(len(stages), 5)
        if count < 1:
            return False

        active_stage = max(0, min(count - 1, active_stage))

        # Build arguments
        args = bytearray(3 + count * 7)
        args[0] = VARSTORE
        args[1] = active_stage
        args[2] = count

        offset = 3
        for i, dpi in enumerate(stages[:5]):
            dpi = max(100, min(30000, dpi))
            args[offset] = i  # Stage number (0-indexed)
            args[offset + 1] = (dpi >> 8) & 0xFF
            args[offset + 2] = dpi & 0xFF
            args[offset + 3] = (dpi >> 8) & 0xFF  # Y = X
            args[offset + 4] = dpi & 0xFF
            args[offset + 5] = 0  # Reserved
            args[offset + 6] = 0
            offset += 7

        request = self._create_report(CMD_CLASS_DPI, CMD_SET_DPI_STAGES, 0x26, bytes(args))
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    def set_active_stage(self, stage: int) -> bool:
        """Set active DPI stage (1-indexed for user, converted to 0-indexed)."""
        current = self.get_dpi_stages()
        if current is None:
            return False

        _, stages = current
        stage_0idx = stage - 1  # Convert to 0-indexed
        if stage_0idx < 0 or stage_0idx >= len(stages):
            return False

        return self.set_dpi_stages(stages, stage_0idx)

    # --- Poll Rate ---
    # Poll rate uses CMD_CLASS_STANDARD (0x00), not MISC

    def get_poll_rate(self) -> Optional[int]:
        """Get polling rate in Hz."""
        # Command: class 0x00, id 0x85 (GET), size 0x01
        request = self._create_report(CMD_CLASS_STANDARD, 0x85, 0x01)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 9:
            rate_byte = response[8]
            rate_map = {0x01: 1000, 0x02: 500, 0x08: 125}
            return rate_map.get(rate_byte, None)
        return None

    def set_poll_rate(self, rate_hz: int) -> bool:
        """Set polling rate (125, 500, or 1000 Hz)."""
        rate_map = {1000: 0x01, 500: 0x02, 125: 0x08}
        rate_byte = rate_map.get(rate_hz)
        if rate_byte is None:
            return False

        # Command: class 0x00, id 0x05 (SET), size 0x01
        args = bytes([rate_byte])
        request = self._create_report(CMD_CLASS_STANDARD, 0x05, 0x01, args)
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    # --- Battery ---

    def get_battery(self) -> Optional[Tuple[int, bool]]:
        """Get battery level (0-100) and charging status.

        Tries USB HID feature report first. If that fails and the device
        is connected via Bluetooth, falls back to BLE Battery Service.
        """
        request = self._create_report(CMD_CLASS_MISC, CMD_GET_BATTERY, 0x02)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            charging = response[8] == 1
            level = int((response[9] / 255.0) * 100)
            return (level, charging)

        # BLE fallback for Bluetooth devices
        if self.vendor_id == BT_VENDOR_ID_RAZER:
            self._dbg("USB battery read failed, trying BLE Battery Service fallback")
            ble_level = self.get_battery_ble()
            if ble_level is not None:
                return (ble_level, False)  # BLE Battery Service doesn't report charging

        return None

    def get_battery_ble(self) -> Optional[int]:
        """Get battery level via BLE Battery Service (0x180F).

        Uses CoreBluetooth to connect to the paired Razer device and read
        the standard Battery Level characteristic. Only works on macOS with
        pyobjc-framework-CoreBluetooth installed.

        Returns battery percentage (0-100) or None.
        """
        level = read_razer_battery_ble(timeout_s=5.0, debug=self.debug_hid)
        if level is not None:
            self._dbg(f"BLE battery level: {level}%")
        return level

    def sniff_bt_dpi_values(self, timeout_s: float = 8.0) -> List[int]:
        """Collect unique DPI values seen in passive BT input reports."""
        if self.vendor_id != BT_VENDOR_ID_RAZER:
            return []

        deadline = time.time() + timeout_s
        dev = None
        values = set()
        try:
            dev = hid.device()
            dev.open_path(self.device_path)
            dev.set_nonblocking(True)
            while time.time() < deadline:
                raw = dev.read(64, timeout_ms=120)
                if not raw:
                    continue
                data = bytes(raw)
                if len(data) < 7:
                    continue
                if data[0] != 0x05 or data[1] != 0x05 or data[2] != 0x02:
                    continue
                dpi_x = (data[3] << 8) | data[4]
                dpi_y = (data[5] << 8) | data[6]
                if dpi_x == dpi_y and 100 <= dpi_x <= 30000:
                    values.add(dpi_x)
        except Exception as e:
            self._dbg(f"bt dpi sniff failed: {type(e).__name__}: {e}")
        finally:
            if dev is not None:
                try:
                    dev.close()
                except Exception:
                    pass
        return sorted(values)


def find_razer_mouse(debug_hid: bool = False) -> Optional[RazerMouse]:
    """Find and return a connected Razer mouse."""
    devices = hid.enumerate()

    # Group by VID:PID
    razer_devices = {}
    for d in devices:
        vid = d['vendor_id']
        pid = d['product_id']

        if vid == USB_VENDOR_ID_RAZER or vid == BT_VENDOR_ID_RAZER:
            key = (vid, pid)
            if key not in razer_devices:
                razer_devices[key] = []
            razer_devices[key].append(d)
            if debug_hid:
                print(f"[hid-debug] candidate vid=0x{vid:04x} pid=0x{pid:04x} usage_page={d.get('usage_page')} usage={d.get('usage')} path={d.get('path')!r} name={(d.get('product_string') or '')}")

    # Check by product name as fallback
    for d in devices:
        name = (d.get('product_string') or '').lower()
        if any(kw in name for kw in ['razer', 'basilisk', 'deathadder', 'viper', 'bsk']):
            key = (d['vendor_id'], d['product_id'])
            if key not in razer_devices:
                razer_devices[key] = []
                razer_devices[key].append(d)
                if debug_hid:
                    print(f"[hid-debug] name-fallback vid=0x{d['vendor_id']:04x} pid=0x{d['product_id']:04x} usage_page={d.get('usage_page')} usage={d.get('usage')} path={d.get('path')!r} name={(d.get('product_string') or '')}")

    if not razer_devices:
        return None

    # Find a working interface
    for (vid, pid), interfaces in razer_devices.items():
        if vid == BT_VENDOR_ID_RAZER:
            print("Bluetooth device detected; trying Bluetooth HID protocol.")
            print("If this fails, use the USB dongle/cable as fallback.\n")

        seen_paths = set()
        for interface in interfaces:
            path = interface.get('path')
            if path in seen_paths:
                continue
            seen_paths.add(path)
            mouse = RazerMouse(
                path,
                interface.get('vendor_id', vid),
                pid,
                interface.get('product_string') or "",
                debug_hid=debug_hid,
            )
            # Test communication
            if mouse.probe_connection():
                return mouse

    return None


def print_status(mouse: RazerMouse):
    """Print current mouse status."""
    print("\n" + "=" * 50)
    print("  Current Settings")
    print("=" * 50)

    # DPI
    dpi = mouse.get_dpi()
    if dpi:
        print(f"\n  Current DPI:    {dpi[0]}" + (f" x {dpi[1]}" if dpi[0] != dpi[1] else ""))

    # DPI Stages
    stages = mouse.get_dpi_stages()
    if stages:
        active, stage_list = stages
        print(f"\n  DPI Stages:     {len(stage_list)} configured")
        for i, dpi in enumerate(stage_list):
            marker = "  <-- active" if i == active else ""
            print(f"    Stage {i+1}:      {dpi}{marker}")

    # Poll Rate
    poll = mouse.get_poll_rate()
    if poll:
        print(f"\n  Poll Rate:      {poll} Hz")

    # Battery
    battery = mouse.get_battery()
    if battery:
        level, charging = battery
        status = " (charging)" if charging else ""
        print(f"\n  Battery:        {level}%{status}")

    print()


def main():
    parser = argparse.ArgumentParser(
        description="Configure Razer mouse settings on macOS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                              Show current settings
  %(prog)s --dpi 1600                   Set DPI to 1600
  %(prog)s --stages 400,800,1600,3200   Set 4 DPI stages
  %(prog)s --stages 800,1600,3200 --active-stage 2
                                        Set stages with stage 2 active
  %(prog)s --poll-rate 1000             Set polling rate to 1000 Hz

Note: USB/dongle is most reliable. Bluetooth HID support is experimental.
        """
    )
    parser.add_argument('--dpi', type=int, metavar='DPI',
                        help='Set current DPI (100-30000)')
    parser.add_argument('--stages', type=str, metavar='DPI,DPI,...',
                        help='Set DPI stages (comma-separated, 1-5 values)')
    parser.add_argument('--active-stage', type=int, metavar='N',
                        help='Set active DPI stage (1-5)')
    parser.add_argument('--poll-rate', type=int, choices=[125, 500, 1000],
                        metavar='HZ', help='Set polling rate (125/500/1000 Hz)')
    parser.add_argument('--quiet', '-q', action='store_true',
                        help='Minimal output')
    parser.add_argument('--debug-hid', action='store_true',
                        help='Enable verbose HID transport debug output')
    parser.add_argument('--battery-ble', action='store_true',
                        help='Read battery level via BLE Battery Service (macOS only)')
    parser.add_argument('--sniff-dpi', nargs='?', const=8.0, type=float, metavar='SECONDS',
                        help='Bluetooth: sniff passive DPI reports for N seconds (default: 8)')

    args = parser.parse_args()

    # Find mouse
    if not args.quiet:
        print("\nSearching for Razer mouse...")

    mouse = find_razer_mouse(debug_hid=args.debug_hid)

    if mouse is None:
        print("\nNo Razer mouse found!")
        print("\nMake sure:")
        print("  - USB dongle is plugged in, OR")
        print("  - Mouse is connected via USB cable")
        print("  - Bluetooth mouse is connected and exposing a HID config interface")
        return 1

    if not args.quiet:
        name, max_dpi = KNOWN_MICE.get(mouse.product_id, ("Razer Mouse", 30000))
        print(f"Found: {name}")

    # Handle commands
    made_changes = False

    if args.stages:
        try:
            stages = [int(x.strip()) for x in args.stages.split(',')]
            if len(stages) < 1 or len(stages) > 5:
                print("Error: Specify 1-5 DPI stages")
                return 1

            active = (args.active_stage - 1) if args.active_stage else 0
            active = max(0, min(len(stages) - 1, active))

            print(f"\nSetting DPI stages: {stages}")
            print(f"Active stage: {active + 1}")

            if mouse.set_dpi_stages(stages, active):
                print("  Success!")
                made_changes = True
            else:
                print("  Failed!")
                return 1
        except ValueError:
            print("Error: Invalid DPI values. Use comma-separated numbers.")
            return 1

    elif args.active_stage:
        print(f"\nSetting active stage to: {args.active_stage}")
        if mouse.set_active_stage(args.active_stage):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed! (Stage out of range?)")
            return 1

    if args.dpi:
        print(f"\nSetting DPI to: {args.dpi}")
        if mouse.set_dpi(args.dpi):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.poll_rate:
        print(f"\nSetting poll rate to: {args.poll_rate} Hz")
        if mouse.set_poll_rate(args.poll_rate):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.battery_ble:
        if not HAS_COREBLUETOOTH:
            print("\n--battery-ble requires pyobjc-framework-CoreBluetooth.")
            print("Install with: pip install pyobjc-framework-CoreBluetooth")
            return 1
        print("\nReading battery via BLE Battery Service...")
        level = mouse.get_battery_ble()
        if level is not None:
            print(f"  Battery: {level}%")
        else:
            print("  Could not read battery via BLE.")
            print("  Make sure the mouse is connected via Bluetooth.")

    if args.sniff_dpi is not None:
        if mouse.vendor_id != BT_VENDOR_ID_RAZER:
            print("\n--sniff-dpi is only supported for Bluetooth devices.")
            return 1
        secs = max(1.0, float(args.sniff_dpi))
        print(f"\nSniffing Bluetooth DPI reports for {secs:.1f}s...")
        values = mouse.sniff_bt_dpi_values(timeout_s=secs)
        if values:
            print("Observed DPI values:", ", ".join(str(v) for v in values))
        else:
            print("No DPI report observed. Move mouse and press DPI button, then retry.")

    # Show status
    if not args.quiet:
        print_status(mouse)

    return 0


if __name__ == "__main__":
    sys.exit(main())
