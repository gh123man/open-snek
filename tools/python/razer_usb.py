#!/usr/bin/env python3
"""
Razer Mouse macOS Configuration Tool

Configure DPI, DPI stages, poll rate, and more for Razer mice on macOS.
USB/2.4GHz dongle transport only.

Usage:
    python3 tools/python/razer_usb.py --help
    python3 tools/python/razer_usb.py            # Show current settings
    python3 tools/python/razer_usb.py --dpi 1600               # Set current DPI
    python3 tools/python/razer_usb.py --stages 400,800,1600    # Set DPI stages
    python3 tools/python/razer_usb.py --active-stage 2         # Set active stage (1-5)
    python3 tools/python/razer_usb.py --poll-rate 1000         # Set poll rate (125/500/1000)
"""

import hid
import sys
from typing import Optional, Tuple, List

from cb_vendor_transport import HAS_CB_VENDOR, _CBVendorTxn
from razer_cli import build_common_parser, dispatch_common_commands
from razer_common import (
    BT_VENDOR_ID_RAZER,
    CMD_CLASS_CONFIG,
    CMD_CLASS_DPI,
    CMD_CLASS_MATRIX,
    CMD_CLASS_MISC,
    CMD_CLASS_STANDARD,
    CMD_GET_BATTERY,
    CMD_GET_DEVICE_MODE,
    CMD_GET_DPI_STAGES,
    CMD_GET_DPI_XY,
    CMD_GET_FIRMWARE,
    CMD_GET_IDLE_TIME,
    CMD_GET_LOW_BATTERY_THRESHOLD,
    CMD_GET_MATRIX_BRIGHTNESS,
    CMD_GET_POLL_RATE,
    CMD_GET_SCROLL_ACCELERATION,
    CMD_GET_SCROLL_MODE,
    CMD_GET_SCROLL_SMART_REEL,
    CMD_SET_BUTTON_ACTION_NON_ANALOG,
    CMD_SET_DEVICE_MODE,
    CMD_SET_DPI_STAGES,
    CMD_SET_DPI_XY,
    CMD_SET_IDLE_TIME,
    CMD_SET_LOW_BATTERY_THRESHOLD,
    CMD_SET_MATRIX_BRIGHTNESS,
    CMD_SET_MATRIX_EFFECT,
    CMD_SET_POLL_RATE,
    CMD_SET_SCROLL_ACCELERATION,
    CMD_SET_SCROLL_MODE,
    CMD_SET_SCROLL_SMART_REEL,
    HAS_COREBLUETOOTH,
    KNOWN_MICE,
    LED_SCROLL_WHEEL,
    NOSTORE,
    RAZER_STATUS_BUSY,
    RAZER_USB_REPORT_LEN,
    RAZER_VENDOR_NOTIFY_UUID,
    RAZER_VENDOR_SERVICE_UUID,
    RAZER_VENDOR_WRITE_UUID,
    STATUS_NAMES,
    STATUS_SUCCESS,
    TRANSACTION_ID_CANDIDATES,
    USB_VENDOR_ID_RAZER,
    VARSTORE,
    print_status,
    read_razer_battery_ble,
)

LIGHTING_LED_IDS_BY_PID = {
    0x00CB: [0x01, 0x04, 0x0A],
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
        self._bt_req_id = 0x30

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

    def _next_bt_req(self) -> int:
        req = self._bt_req_id
        self._bt_req_id = (self._bt_req_id + 1) & 0xFF
        return req

    def _bt_vendor_exchange(self, writes: List[bytes], timeout_s: float = 2.0) -> Optional[List[bytes]]:
        if self.vendor_id != BT_VENDOR_ID_RAZER or not HAS_CB_VENDOR:
            return None
        try:
            txn = _CBVendorTxn(
                RAZER_VENDOR_SERVICE_UUID,
                RAZER_VENDOR_WRITE_UUID,
                RAZER_VENDOR_NOTIFY_UUID,
                debug=self.debug_hid,
            )
            err, notifs = txn.run(writes, timeout_s=timeout_s)
            if err is not None:
                self._dbg(f"bt vendor exchange error: {err}")
                return None
            return notifs
        except Exception as e:
            self._dbg(f"bt vendor exchange failed: {type(e).__name__}: {e}")
            return None

    def _bt_get_dpi_stages_blob(self) -> Optional[bytes]:
        req = self._next_bt_req()
        cmd = bytes([req, 0x00, 0x00, 0x00, 0x0B, 0x84, 0x01, 0x00])
        notifs = self._bt_vendor_exchange([cmd], timeout_s=2.2)
        if not notifs:
            return None

        header_idx = -1
        header = None
        for i, n in enumerate(notifs):
            if len(n) == 20 and n[0] == req and n[7] in (0x02, 0x03, 0x05):
                header_idx = i
                header = n
                break
        if header is None or header[7] != 0x02:
            return None

        # Standard staged mode: two 20-byte continuations. Single-DPI mode can return one short continuation.
        cont = [n for n in notifs[header_idx + 1:] if len(n) == 20]
        if len(cont) >= 2:
            return cont[0] + cont[1]
        if len(cont) == 1:
            return cont[0]
        return None

    def _bt_set_dpi_stages_blob(self, payload: bytes) -> bool:
        if len(payload) != 38:
            return False
        req = self._next_bt_req()
        header = bytes([req, 0x26, 0x00, 0x00, 0x0B, 0x04, 0x01, 0x00])
        notifs = self._bt_vendor_exchange([header, payload[:20], payload[20:]], timeout_s=2.2)
        if not notifs:
            return False
        for n in notifs:
            if len(n) == 20 and n[0] == req and n[7] == 0x02:
                return True
        return False

    @staticmethod
    def _parse_bt_stage_table(blob: bytes) -> Optional[Tuple[int, int, List[Tuple[int, int]], int]]:
        # Full staged blob observed as 40 bytes.
        if len(blob) >= 37:
            active = blob[0]
            count = blob[1]
            offsets = [2, 9, 16, 23, 30]
            stages = []
            for off in offsets:
                if off + 5 > len(blob):
                    return None
                dpi_x = int.from_bytes(blob[off + 1:off + 3], 'little')
                dpi_y = int.from_bytes(blob[off + 3:off + 5], 'little')
                stages.append((dpi_x, dpi_y))
            marker = blob[36] if len(blob) > 36 else 0x03
            return (active, count, stages, marker)

        # Single-stage mode can present as 8-byte blob: [active][count][sid][x][y][reserved]
        if len(blob) >= 7:
            active = blob[0]
            count = blob[1]
            dpi_x = int.from_bytes(blob[3:5], 'little')
            dpi_y = int.from_bytes(blob[5:7], 'little')
            stages = [(dpi_x, dpi_y)] * 5
            return (active, count, stages, 0x03)

        return None

    @staticmethod
    def _build_bt_stage_payload(active: int, count: int, stages: List[Tuple[int, int]], marker: int) -> bytes:
        # Vendor write payload: 38 bytes -> [active][count] + 5x7-byte slots + trailing 0x00
        out = bytearray([active & 0xFF, count & 0xFF])
        for i in range(5):
            dpi_x, dpi_y = stages[i]
            out.append(i)  # stage id in set payload is 0..4
            out.extend(int(dpi_x).to_bytes(2, 'little'))
            out.extend(int(dpi_y).to_bytes(2, 'little'))
            out.append(0x00)
            out.append(marker if i == 4 else 0x00)
        out.append(0x00)
        return bytes(out)

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
        if self.vendor_id == BT_VENDOR_ID_RAZER:
            blob = self._bt_get_dpi_stages_blob()
            parsed = self._parse_bt_stage_table(blob) if blob else None
            if parsed is None:
                return None
            active, count, stages, _ = parsed
            count = max(1, min(5, count))
            values = [max(100, min(30000, stages[i][0])) for i in range(count)]
            active = max(0, min(count - 1, active))
            return (active, values)

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

        if self.vendor_id == BT_VENDOR_ID_RAZER:
            current_blob = self._bt_get_dpi_stages_blob()
            parsed = self._parse_bt_stage_table(current_blob) if current_blob else None
            if parsed is None:
                return False
            _, _, current_stages, marker = parsed

            stage_xy = [(max(100, min(30000, x)), max(100, min(30000, y))) for x, y in current_stages[:5]]
            first = max(100, min(30000, stages[0]))
            for i in range(5):
                if i < count:
                    val = max(100, min(30000, stages[i]))
                    stage_xy[i] = (val, val)
                elif count == 1:
                    # Single fixed DPI mode: mirror stage 0 across all slots.
                    stage_xy[i] = (first, first)

            payload = self._build_bt_stage_payload(active_stage, count, stage_xy, marker)
            return self._bt_set_dpi_stages_blob(payload)

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

    # --- Device Identity / Mode ---

    def get_serial(self) -> Optional[str]:
        request = self._create_report(CMD_CLASS_STANDARD, CMD_GET_SERIAL, 0x16)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 30:
            raw = bytes(response[8:30]).split(b"\x00", 1)[0]
            serial = raw.decode("ascii", errors="ignore").strip()
            return serial or None
        return None

    def get_firmware(self) -> Optional[Tuple[int, int]]:
        request = self._create_report(CMD_CLASS_STANDARD, CMD_GET_FIRMWARE, 0x02)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            return (response[8], response[9])
        return None

    def get_device_mode(self) -> Optional[Tuple[int, int]]:
        request = self._create_report(CMD_CLASS_STANDARD, CMD_GET_DEVICE_MODE, 0x02)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            return (response[8], response[9])
        return None

    def set_device_mode(self, mode: int, param: int = 0x00) -> bool:
        mode = int(mode)
        param = int(param) & 0xFF
        if mode not in (0x00, 0x03):
            return False
        request = self._create_report(CMD_CLASS_STANDARD, CMD_SET_DEVICE_MODE, 0x02, bytes([mode, param]))
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    # --- Power / Battery Threshold ---

    def get_idle_time(self) -> Optional[int]:
        request = self._create_report(CMD_CLASS_MISC, CMD_GET_IDLE_TIME, 0x02)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            return (response[8] << 8) | response[9]
        return None

    def set_idle_time(self, seconds: int) -> bool:
        seconds = max(60, min(900, int(seconds)))
        args = bytes([(seconds >> 8) & 0xFF, seconds & 0xFF])
        request = self._create_report(CMD_CLASS_MISC, CMD_SET_IDLE_TIME, 0x02, args)
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    def get_low_battery_threshold(self) -> Optional[int]:
        request = self._create_report(CMD_CLASS_MISC, CMD_GET_LOW_BATTERY_THRESHOLD, 0x01)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 9:
            return response[8]
        return None

    def set_low_battery_threshold(self, threshold_raw: int) -> bool:
        threshold = max(0x0C, min(0x3F, int(threshold_raw)))
        request = self._create_report(CMD_CLASS_MISC, CMD_SET_LOW_BATTERY_THRESHOLD, 0x01, bytes([threshold]))
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    # --- Scroll Wheel Controls ---

    def get_scroll_mode(self) -> Optional[int]:
        request = self._create_report(CMD_CLASS_CONFIG, CMD_GET_SCROLL_MODE, 0x02, bytes([VARSTORE, 0x00]))
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            return response[9]
        return None

    def set_scroll_mode(self, mode: int) -> bool:
        mode = 1 if int(mode) else 0
        request = self._create_report(CMD_CLASS_CONFIG, CMD_SET_SCROLL_MODE, 0x02, bytes([VARSTORE, mode]))
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    def get_scroll_acceleration(self) -> Optional[bool]:
        request = self._create_report(CMD_CLASS_CONFIG, CMD_GET_SCROLL_ACCELERATION, 0x02, bytes([VARSTORE, 0x00]))
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            return bool(response[9])
        return None

    def set_scroll_acceleration(self, enabled: bool) -> bool:
        val = 1 if enabled else 0
        request = self._create_report(CMD_CLASS_CONFIG, CMD_SET_SCROLL_ACCELERATION, 0x02, bytes([VARSTORE, val]))
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    def get_scroll_smart_reel(self) -> Optional[bool]:
        request = self._create_report(CMD_CLASS_CONFIG, CMD_GET_SCROLL_SMART_REEL, 0x02, bytes([VARSTORE, 0x00]))
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            return bool(response[9])
        return None

    def set_scroll_smart_reel(self, enabled: bool) -> bool:
        val = 1 if enabled else 0
        request = self._create_report(CMD_CLASS_CONFIG, CMD_SET_SCROLL_SMART_REEL, 0x02, bytes([VARSTORE, val]))
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    # --- Scroll LED Controls (OpenRazer-derived, class 0x0F) ---

    def _matrix_led_ids(self) -> List[int]:
        return LIGHTING_LED_IDS_BY_PID.get(self.product_id, [LED_SCROLL_WHEEL])

    def _get_matrix_brightness(self, led_id: int) -> Optional[int]:
        request = self._create_report(
            CMD_CLASS_MATRIX,
            CMD_GET_MATRIX_BRIGHTNESS,
            0x03,
            bytes([VARSTORE, led_id & 0xFF, 0x00]),
        )
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 11:
            return response[10]
        return None

    def _set_matrix_brightness(self, led_id: int, brightness: int) -> bool:
        request = self._create_report(
            CMD_CLASS_MATRIX,
            CMD_SET_MATRIX_BRIGHTNESS,
            0x03,
            bytes([VARSTORE, led_id & 0xFF, brightness & 0xFF]),
        )
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    def _set_matrix_effect_for_leds(self, payload_builder) -> bool:
        wrote_any = False
        for led_id in self._matrix_led_ids():
            args = payload_builder(led_id & 0xFF)
            request = self._create_report(CMD_CLASS_MATRIX, CMD_SET_MATRIX_EFFECT, len(args), args)
            response = self._send_command(request)
            if response is None or response[0] != STATUS_SUCCESS:
                return False
            wrote_any = True
        return wrote_any

    def get_scroll_led_brightness(self) -> Optional[int]:
        values = [value for led_id in self._matrix_led_ids() if (value := self._get_matrix_brightness(led_id)) is not None]
        return max(values) if values else None

    def set_scroll_led_brightness(self, brightness: int) -> bool:
        brightness = max(0, min(255, int(brightness)))
        wrote_any = False
        for led_id in self._matrix_led_ids():
            if not self._set_matrix_brightness(led_id, brightness):
                return False
            wrote_any = True
        return wrote_any

    def _set_scroll_led_effect_raw(self, args: bytes) -> bool:
        base = bytes(args)
        if len(base) < 2:
            return False
        return self._set_matrix_effect_for_leds(
            lambda led_id: bytes([base[0], led_id]) + base[2:]
        )

    def set_scroll_led_effect_none(self) -> bool:
        return self._set_scroll_led_effect_raw(bytes([VARSTORE, LED_SCROLL_WHEEL, 0x00, 0x00, 0x00, 0x00]))

    def set_scroll_led_effect_spectrum(self) -> bool:
        return self._set_scroll_led_effect_raw(bytes([VARSTORE, LED_SCROLL_WHEEL, 0x03, 0x00, 0x00, 0x00]))

    def set_scroll_led_effect_wave(self, direction: int = 1) -> bool:
        d = 1 if int(direction) <= 1 else 2
        return self._set_scroll_led_effect_raw(bytes([VARSTORE, LED_SCROLL_WHEEL, 0x04, d, 0x28, 0x00]))

    def set_scroll_led_effect_static(self, r: int, g: int, b: int) -> bool:
        return self._set_scroll_led_effect_raw(
            bytes([VARSTORE, LED_SCROLL_WHEEL, 0x01, 0x00, 0x00, 0x01, r & 0xFF, g & 0xFF, b & 0xFF])
        )

    def set_scroll_led_effect_reactive(self, speed: int, r: int, g: int, b: int) -> bool:
        s = max(1, min(4, int(speed)))
        return self._set_scroll_led_effect_raw(
            bytes([VARSTORE, LED_SCROLL_WHEEL, 0x05, 0x00, s, 0x01, r & 0xFF, g & 0xFF, b & 0xFF])
        )

    def set_scroll_led_effect_breath_random(self) -> bool:
        return self._set_scroll_led_effect_raw(bytes([VARSTORE, LED_SCROLL_WHEEL, 0x02, 0x00, 0x00, 0x00]))

    def set_scroll_led_effect_breath_single(self, r: int, g: int, b: int) -> bool:
        return self._set_scroll_led_effect_raw(
            bytes([VARSTORE, LED_SCROLL_WHEEL, 0x02, 0x01, 0x00, 0x01, r & 0xFF, g & 0xFF, b & 0xFF])
        )

    def set_scroll_led_effect_breath_dual(self, r1: int, g1: int, b1: int, r2: int, g2: int, b2: int) -> bool:
        return self._set_scroll_led_effect_raw(
            bytes(
                [
                    VARSTORE,
                    LED_SCROLL_WHEEL,
                    0x02,
                    0x02,
                    0x00,
                    0x02,
                    r1 & 0xFF,
                    g1 & 0xFF,
                    b1 & 0xFF,
                    r2 & 0xFF,
                    g2 & 0xFF,
                    b2 & 0xFF,
                ]
            )
        )

    # --- USB Button Actions (experimental) ---

    def set_usb_button_action(
        self,
        profile: int,
        button_id: int,
        action_type: int,
        param_bytes: bytes,
        fn_hypershift: bool = False,
    ) -> bool:
        """
        Experimental non-analog button action write (class 0x02, id 0x0d).

        Payload layout (capture/OpenRazer-derived high-level format):
          [0]=profile
          [1]=button_id
          [2]=fn/hypershift flag
          [3-4]=actuation (0x0000 for non-analog)
          [5]=action_type
          [6]=param length
          [7..]=params
        """
        p = int(profile) & 0xFF
        b = int(button_id) & 0xFF
        fn = 0x01 if fn_hypershift else 0x00
        t = int(action_type) & 0xFF
        params = bytes(param_bytes)
        if len(params) > 72:
            return False

        args = bytes([p, b, fn, 0x00, 0x00, t, len(params)]) + params
        request = self._create_report(
            CMD_CLASS_CONFIG,
            CMD_SET_BUTTON_ACTION_NON_ANALOG,
            len(args),
            args,
        )
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
    """Find and return a connected USB/dongle Razer mouse."""
    devices = hid.enumerate()

    # Group by VID:PID
    razer_devices = {}
    for d in devices:
        vid = d['vendor_id']
        pid = d['product_id']

        if vid == USB_VENDOR_ID_RAZER:
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


def main():
    parser = build_common_parser(note="This script targets USB and 2.4GHz dongle transport.")
    args = parser.parse_args()
    if not args.quiet:
        print("\nSearching for Razer mouse...")

    mouse = find_razer_mouse(debug_hid=args.debug_hid)

    if mouse is None:
        print("\nNo Razer mouse found!")
        print("\nMake sure:")
        print("  - USB dongle is plugged in, OR")
        print("  - Mouse is connected via USB cable")
        return 1

    if not args.quiet:
        name, _max_dpi = KNOWN_MICE.get(mouse.product_id, ("Razer Mouse", 30000))
        print(f"Found: {name}")

    exit_code, _made_changes = dispatch_common_commands(mouse, args)
    if exit_code != 0:
        return exit_code

    if not args.quiet:
        print_status(mouse)
    return 0


if __name__ == "__main__":
    sys.exit(main())
