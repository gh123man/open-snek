#!/usr/bin/env python3
"""
Razer Mouse macOS Configuration Tool

Configure DPI, DPI stages, poll rate, and more for Razer mice on macOS.
Requires USB connection (dongle or cable) - Bluetooth is not supported.

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

# Constants
USB_VENDOR_ID_RAZER = 0x1532
BT_VENDOR_ID_RAZER = 0x068e
RAZER_USB_REPORT_LEN = 90

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

# Device info
KNOWN_MICE = {
    0x00B9: ("Razer Basilisk V3 X HyperSpeed", 18000),
    0x0083: ("Razer Basilisk V3", 26000),
    0x0084: ("Razer Basilisk V3", 26000),
    0x00BA: ("Razer Basilisk V3 X HyperSpeed (BT)", 18000),
}


class RazerMouse:
    """Interface for communicating with a Razer mouse."""

    def __init__(self, device_path: bytes, product_id: int):
        self.device_path = device_path
        self.product_id = product_id
        self.txn_id = 0x1F  # Most modern mice use this

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

    def _send_command(self, request: bytes) -> Optional[bytes]:
        """Send command and get response."""
        try:
            dev = hid.device()
            dev.open_path(self.device_path)
            dev.set_nonblocking(False)

            report = bytes([0x00]) + request
            result = dev.send_feature_report(report)

            if result > 0:
                time.sleep(0.03)
                response = dev.get_feature_report(0x00, RAZER_USB_REPORT_LEN + 1)
                dev.close()
                if response and len(response) > 1:
                    return bytes(response[1:])

            dev.close()
        except Exception as e:
            pass
        return None

    # --- DPI ---

    def get_dpi(self) -> Optional[Tuple[int, int]]:
        """Get current DPI (X, Y)."""
        request = self._create_report(CMD_CLASS_DPI, CMD_GET_DPI_XY, 0x07, bytes([NOSTORE]))
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 13:
            dpi_x = (response[9] << 8) | response[10]
            dpi_y = (response[11] << 8) | response[12]
            return (dpi_x, dpi_y)
        return None

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
        """Get battery level (0-100) and charging status."""
        request = self._create_report(CMD_CLASS_MISC, CMD_GET_BATTERY, 0x02)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            charging = response[8] == 1
            level = int((response[9] / 255.0) * 100)
            return (level, charging)
        return None


def find_razer_mouse() -> Optional[RazerMouse]:
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

    # Check by product name as fallback
    for d in devices:
        name = (d.get('product_string') or '').lower()
        if any(kw in name for kw in ['razer', 'basilisk', 'deathadder', 'viper', 'bsk']):
            key = (d['vendor_id'], d['product_id'])
            if key not in razer_devices:
                razer_devices[key] = []
                razer_devices[key].append(d)

    if not razer_devices:
        return None

    # Find a working interface
    for (vid, pid), interfaces in razer_devices.items():
        if vid == BT_VENDOR_ID_RAZER:
            print(f"Note: Device connected via Bluetooth - configuration may not work.")
            print(f"      Use the USB dongle for full functionality.\n")

        for interface in interfaces:
            mouse = RazerMouse(interface['path'], pid)
            # Test communication
            if mouse.get_dpi() is not None:
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

Note: Requires USB connection (dongle or cable). Bluetooth is not supported.
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

    args = parser.parse_args()

    # Find mouse
    if not args.quiet:
        print("\nSearching for Razer mouse...")

    mouse = find_razer_mouse()

    if mouse is None:
        print("\nNo Razer mouse found!")
        print("\nMake sure:")
        print("  - USB dongle is plugged in, OR")
        print("  - Mouse is connected via USB cable")
        print("  - Bluetooth connection is NOT supported for configuration")
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

    # Show status
    if not args.quiet:
        print_status(mouse)

    return 0


if __name__ == "__main__":
    sys.exit(main())
