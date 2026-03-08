#!/usr/bin/env python3
"""
Razer Mouse macOS Configuration Tool

Configure BLE settings for Razer mice on macOS.
Bluetooth transport only.

Usage:
    python razer_ble.py                          # Show current settings
    python razer_ble.py --single-dpi 1600        # Set one fixed DPI stage
    python razer_ble.py --stages 800,1600,3200   # Set staged DPI profile
    python razer_ble.py --active-stage 2         # Set active stage (1-5)
"""

import argparse
import hid
import time
import sys
import threading
from typing import Optional, Tuple, List

try:
    from ble_battery import read_razer_battery_ble, HAS_COREBLUETOOTH
except ImportError:
    HAS_COREBLUETOOTH = False

    def read_razer_battery_ble(**kwargs):
        return None

try:
    import objc
    from CoreBluetooth import CBCentralManager, CBUUID
    from Foundation import NSObject, NSRunLoop, NSDate, NSData
    HAS_CB_VENDOR = True
except Exception:
    HAS_CB_VENDOR = False

# Constants
USB_VENDOR_ID_RAZER = 0x1532
BT_VENDOR_ID_RAZER = 0x068e
RAZER_USB_REPORT_LEN = 90
RAZER_STATUS_BUSY = 0x01

# Commands
CMD_CLASS_STANDARD = 0x00
CMD_CLASS_CONFIG = 0x02
CMD_CLASS_DPI = 0x04
CMD_CLASS_MISC = 0x07
CMD_CLASS_MATRIX = 0x0F

CMD_GET_DEVICE_MODE = 0x84
CMD_SET_DEVICE_MODE = 0x04
CMD_GET_SERIAL = 0x82
CMD_GET_FIRMWARE = 0x81
CMD_GET_DPI_XY = 0x85
CMD_SET_DPI_XY = 0x05
CMD_GET_DPI_STAGES = 0x86
CMD_SET_DPI_STAGES = 0x06
CMD_GET_POLL_RATE = 0x85
CMD_SET_POLL_RATE = 0x05
CMD_GET_BATTERY = 0x80
CMD_GET_IDLE_TIME = 0x83
CMD_SET_IDLE_TIME = 0x03
CMD_GET_LOW_BATTERY_THRESHOLD = 0x81
CMD_SET_LOW_BATTERY_THRESHOLD = 0x01
CMD_GET_SCROLL_MODE = 0x94
CMD_SET_SCROLL_MODE = 0x14
CMD_GET_SCROLL_ACCELERATION = 0x96
CMD_SET_SCROLL_ACCELERATION = 0x16
CMD_GET_SCROLL_SMART_REEL = 0x97
CMD_SET_SCROLL_SMART_REEL = 0x17
CMD_SET_BUTTON_ACTION_NON_ANALOG = 0x0D
CMD_GET_MATRIX_BRIGHTNESS = 0x84
CMD_SET_MATRIX_BRIGHTNESS = 0x04
CMD_SET_MATRIX_EFFECT = 0x02

NOSTORE = 0x00
VARSTORE = 0x01
STATUS_SUCCESS = 0x02
LED_SCROLL_WHEEL = 0x01
STATUS_NAMES = {
    0x00: "new",
    0x01: "busy",
    0x02: "success",
    0x03: "failure",
    0x04: "timeout",
    0x05: "not_supported",
}

RAZER_VENDOR_SERVICE_UUID = "52401523-F97C-7F90-0E7F-6C6F4E36DB1C"
RAZER_VENDOR_WRITE_UUID = "52401524-F97C-7F90-0E7F-6C6F4E36DB1C"
RAZER_VENDOR_NOTIFY_UUID = "52401525-F97C-7F90-0E7F-6C6F4E36DB1C"

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


if HAS_CB_VENDOR:
    class _CBVendorTxnDelegate(NSObject):
        def initWithOwner_(self, owner):
            self = objc.super(_CBVendorTxnDelegate, self).init()
            if self is None:
                return None
            self._owner = owner
            return self

        def centralManagerDidUpdateState_(self, central):
            self._owner._on_central_state(central)

        def centralManager_didConnectPeripheral_(self, central, peripheral):
            self._owner._on_connected(peripheral)

        def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
            self._owner._on_error(f"connect failed: {error}")

        def peripheral_didDiscoverServices_(self, peripheral, error):
            self._owner._on_services(peripheral, error)

        def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
            self._owner._on_characteristics(peripheral, service, error)

        def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, peripheral, characteristic, error):
            self._owner._on_notify_state(characteristic, error)

        def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, characteristic, error):
            if error is not None:
                self._owner._on_error(f"write failed: {error}")

        def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, characteristic, error):
            self._owner._on_notify(characteristic, error)


    class _CBVendorTxn:
        def __init__(self, debug: bool = False):
            self.debug = debug
            self.done = threading.Event()
            self.error = None
            self.notifs: List[bytes] = []
            self.peripheral = None
            self.manager = None
            self.write_char = None
            self.notify_char = None
            self._write_queue: List[bytes] = []
            self._last_write_at = 0.0
            self._notify_enabled = False

        def _dbg(self, msg: str):
            if self.debug:
                print(f"[hid-debug] {msg}")

        def _on_error(self, msg: str):
            self.error = msg
            self._dbg(msg)
            self.done.set()

        def _on_central_state(self, central):
            state = central.state()
            if state != 5:
                return
            uuid = CBUUID.UUIDWithString_(RAZER_VENDOR_SERVICE_UUID)
            peripherals = central.retrieveConnectedPeripheralsWithServices_([uuid])
            if not peripherals:
                self._on_error("no connected Razer vendor-service peripheral")
                return
            self.peripheral = peripherals[0]
            self.peripheral.setDelegate_(self._delegate)
            central.connectPeripheral_options_(self.peripheral, None)

        def _on_connected(self, peripheral):
            uuid = CBUUID.UUIDWithString_(RAZER_VENDOR_SERVICE_UUID)
            peripheral.discoverServices_([uuid])

        def _on_services(self, peripheral, error):
            if error is not None:
                self._on_error(f"service discovery failed: {error}")
                return
            for service in peripheral.services() or []:
                peripheral.discoverCharacteristics_forService_(None, service)

        def _on_characteristics(self, peripheral, service, error):
            if error is not None:
                self._on_error(f"char discovery failed: {error}")
                return
            for ch in service.characteristics() or []:
                uuid = ch.UUID().UUIDString().upper()
                if uuid == RAZER_VENDOR_WRITE_UUID:
                    self.write_char = ch
                elif uuid == RAZER_VENDOR_NOTIFY_UUID:
                    self.notify_char = ch
            if self.write_char is not None and self.notify_char is not None and not self._notify_enabled:
                peripheral.setNotifyValue_forCharacteristic_(True, self.notify_char)

        def _on_notify_state(self, characteristic, error):
            if error is not None:
                self._on_error(f"notify enable failed: {error}")
                return
            if characteristic.isNotifying():
                self._notify_enabled = True

        def _on_notify(self, characteristic, error):
            if error is not None:
                self._on_error(f"notify update failed: {error}")
                return
            value = characteristic.value()
            if value is None:
                return
            self.notifs.append(bytes(value))

        def _drain(self, duration_s: float):
            end = time.time() + duration_s
            while time.time() < end and not self.done.is_set():
                NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.015))

        def run(self, writes: List[bytes], timeout_s: float = 2.0) -> Tuple[Optional[str], List[bytes]]:
            self._write_queue = list(writes)
            self.notifs = []
            self.done.clear()
            self.error = None
            self._notify_enabled = False

            self._delegate = _CBVendorTxnDelegate.alloc().initWithOwner_(self)
            self.manager = CBCentralManager.alloc().initWithDelegate_queue_(self._delegate, None)

            start = time.time()
            while time.time() - start < timeout_s and not self.done.is_set():
                self._drain(0.02)
                if self._notify_enabled and self._write_queue:
                    chunk = self._write_queue.pop(0)
                    data = NSData.dataWithBytes_length_(chunk, len(chunk))
                    self.peripheral.writeValue_forCharacteristic_type_(data, self.write_char, 0)
                    self._last_write_at = time.time()
                    self._drain(0.06)
                if self._notify_enabled and not self._write_queue and time.time() - self._last_write_at > 0.55:
                    break

            return (self.error, self.notifs)


class RazerMouse:
    """Interface for communicating with a Razer mouse."""

    def __init__(
        self,
        device_path: bytes,
        vendor_id: int,
        product_id: int,
        product_name: str = "",
        debug_hid: bool = False,
        enable_vendor_gatt: bool = False,
    ):
        self.device_path = device_path
        self.vendor_id = vendor_id
        self.product_id = product_id
        self.product_name = product_name
        self.debug_hid = debug_hid
        self.enable_vendor_gatt = enable_vendor_gatt
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
        # CoreBluetooth vendor GATT path is unstable on some macOS stacks.
        # Keep it opt-in to avoid hard crashes.
        if not self.enable_vendor_gatt:
            return None
        if self.vendor_id != BT_VENDOR_ID_RAZER or not HAS_CB_VENDOR:
            return None
        try:
            txn = _CBVendorTxn(debug=self.debug_hid)
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

    def _bt_get_scalar(self, key4: bytes, size: int) -> Optional[int]:
        if self.vendor_id != BT_VENDOR_ID_RAZER or len(key4) != 4:
            return None
        req = self._next_bt_req()
        cmd = bytes([req, 0x00, 0x00, 0x00]) + key4
        notifs = self._bt_vendor_exchange([cmd], timeout_s=1.8)
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

        for n in notifs[header_idx + 1:]:
            if len(n) == 20:
                raw = bytes(n[:size])
                return int.from_bytes(raw, 'little')
        return None

    def _bt_set_scalar(self, key4: bytes, op: int, value: int, size: int) -> bool:
        if self.vendor_id != BT_VENDOR_ID_RAZER or len(key4) != 4:
            return False
        req = self._next_bt_req()
        header = bytes([req, op & 0xFF, 0x00, 0x00]) + key4
        payload = int(value).to_bytes(size, 'little', signed=False)
        notifs = self._bt_vendor_exchange([header, payload], timeout_s=1.8)
        if not notifs:
            return False
        for n in notifs:
            if len(n) == 20 and n[0] == req and n[7] == 0x02:
                return True
        return False

    def get_power_timeout_raw(self) -> Optional[int]:
        """Vendor key 05 84 00 00 (u16 LE)."""
        return self._bt_get_scalar(bytes([0x05, 0x84, 0x00, 0x00]), 2)

    def set_power_timeout_raw(self, value: int) -> bool:
        """Vendor key 05 04 00 00 (u16 LE)."""
        value = max(0, min(0xFFFF, int(value)))
        return self._bt_set_scalar(bytes([0x05, 0x04, 0x00, 0x00]), 0x02, value, 2)

    def get_sleep_timeout_raw(self) -> Optional[int]:
        """Vendor key 05 82 00 00 (u8)."""
        return self._bt_get_scalar(bytes([0x05, 0x82, 0x00, 0x00]), 1)

    def set_sleep_timeout_raw(self, value: int) -> bool:
        """Vendor key 05 02 00 00 (u8)."""
        value = max(0, min(0xFF, int(value)))
        return self._bt_set_scalar(bytes([0x05, 0x02, 0x00, 0x00]), 0x01, value, 1)

    def get_lighting_value_raw(self) -> Optional[int]:
        """Vendor key 10 85 01 01 (u8)."""
        return self._bt_get_scalar(bytes([0x10, 0x85, 0x01, 0x01]), 1)

    def set_lighting_value_raw(self, value: int) -> bool:
        """Vendor key 10 05 01 00 (u8)."""
        value = max(0, min(0xFF, int(value)))
        return self._bt_set_scalar(bytes([0x10, 0x05, 0x01, 0x00]), 0x01, value, 1)

    def get_battery_vendor_raw(self) -> Optional[int]:
        """Vendor key 05 81 00 01 (u8 raw battery level)."""
        return self._bt_get_scalar(bytes([0x05, 0x81, 0x00, 0x01]), 1)

    def get_battery_status_vendor_raw(self) -> Optional[int]:
        """Vendor key 05 80 00 01 (u8 status flag; semantics still being mapped)."""
        return self._bt_get_scalar(bytes([0x05, 0x80, 0x00, 0x01]), 1)

    def set_button_binding_raw(self, slot: int, payload10: bytes) -> bool:
        """
        Set button binding entry via vendor key 08 04 01 <slot>.

        Capture-backed framing:
          header: [req] 0a 00 00 08 04 01 <slot>
          payload: 10 bytes
        """
        if self.vendor_id != BT_VENDOR_ID_RAZER:
            return False
        if not (0 <= int(slot) <= 0xFF):
            return False
        if len(payload10) != 10:
            return False

        req = self._next_bt_req()
        header = bytes([req, 0x0A, 0x00, 0x00, 0x08, 0x04, 0x01, int(slot) & 0xFF])
        notifs = self._bt_vendor_exchange([header, payload10], timeout_s=2.0)
        if not notifs:
            return False
        for n in notifs:
            if len(n) == 20 and n[0] == req and n[7] == 0x02:
                return True
        return False

    @staticmethod
    def _build_button_payload_action(slot: int, action_type: int, param0_u16: int, param1_u16: int, param2_u16: int) -> bytes:
        # Capture-backed layout: [profile=01][slot][layer=00][action][p0_le16][p1_le16][p2_le16]
        return bytes([
            0x01,
            slot & 0xFF,
            0x00,
            action_type & 0xFF,
            param0_u16 & 0xFF, (param0_u16 >> 8) & 0xFF,
            param1_u16 & 0xFF, (param1_u16 >> 8) & 0xFF,
            param2_u16 & 0xFF, (param2_u16 >> 8) & 0xFF,
        ])

    @staticmethod
    def _build_button_payload_default(slot: int) -> bytes:
        # Observed pattern: 01 <slot> 00 01 0000 0000 0000
        return RazerMouse._build_button_payload_action(slot, 0x01, 0x0000, 0x0000, 0x0000)

    @staticmethod
    def _build_button_payload_keyboard_simple(slot: int, hid_key: int) -> bytes:
        # Observed pattern: 01 <slot> 00 02 0200 <hid_key> 0000
        return RazerMouse._build_button_payload_action(slot, 0x02, 0x0002, hid_key & 0xFFFF, 0x0000)

    @staticmethod
    def _build_button_payload_keyboard_extended(slot: int, primary_u16: int, secondary_u16: int) -> bytes:
        # Observed variant: action 0x0d with params like 0400 0800 8e00
        return RazerMouse._build_button_payload_action(slot, 0x0D, 0x0004, primary_u16 & 0xFFFF, secondary_u16 & 0xFFFF)

    @staticmethod
    def _build_button_payload_mouse_button(slot: int, mouse_button_id: int) -> bytes:
        # right-click-bind.pcapng confirms slot 0x02:
        # left click => action 0x01, p0=0x0101 ; right click => action 0x01, p0=0x0201.
        p0 = ((int(mouse_button_id) & 0xFF) << 8) | 0x01
        return RazerMouse._build_button_payload_action(slot, 0x01, p0, 0x0000, 0x0000)

    def set_button_default(self, slot: int) -> bool:
        slot = int(slot)
        # Capture-backed special case: slot 0x02 default is explicit right-click action.
        if slot == 0x02:
            return self.set_button_binding_raw(slot, self._build_button_payload_mouse_button(slot, 0x02))
        return self.set_button_binding_raw(slot, self._build_button_payload_default(slot))

    def set_button_mouse_button(self, slot: int, mouse_button_id: int) -> bool:
        slot = int(slot)
        return self.set_button_binding_raw(slot, self._build_button_payload_mouse_button(slot, int(mouse_button_id)))

    def set_button_left_click(self, slot: int) -> bool:
        return self.set_button_mouse_button(slot, 0x01)

    def set_button_right_click(self, slot: int) -> bool:
        return self.set_button_mouse_button(slot, 0x02)

    def set_button_keyboard_simple(self, slot: int, hid_key: int) -> bool:
        slot = int(slot)
        return self.set_button_binding_raw(slot, self._build_button_payload_keyboard_simple(slot, int(hid_key)))

    def set_button_keyboard_extended(self, slot: int, primary_u16: int, secondary_u16: int) -> bool:
        slot = int(slot)
        return self.set_button_binding_raw(slot, self._build_button_payload_keyboard_extended(slot, int(primary_u16), int(secondary_u16)))

    def set_button_action_u16(self, slot: int, action_type: int, param0_u16: int, param1_u16: int, param2_u16: int) -> bool:
        slot = int(slot)
        payload = self._build_button_payload_action(slot, int(action_type), int(param0_u16), int(param1_u16), int(param2_u16))
        return self.set_button_binding_raw(slot, payload)

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

    def get_scroll_led_brightness(self) -> Optional[int]:
        request = self._create_report(
            CMD_CLASS_MATRIX,
            CMD_GET_MATRIX_BRIGHTNESS,
            0x03,
            bytes([VARSTORE, LED_SCROLL_WHEEL, 0x00]),
        )
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 11:
            return response[10]
        return None

    def set_scroll_led_brightness(self, brightness: int) -> bool:
        brightness = max(0, min(255, int(brightness)))
        request = self._create_report(
            CMD_CLASS_MATRIX,
            CMD_SET_MATRIX_BRIGHTNESS,
            0x03,
            bytes([VARSTORE, LED_SCROLL_WHEEL, brightness]),
        )
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

    def _set_scroll_led_effect_raw(self, args: bytes) -> bool:
        request = self._create_report(CMD_CLASS_MATRIX, CMD_SET_MATRIX_EFFECT, len(args), args)
        response = self._send_command(request)
        return response is not None and response[0] == STATUS_SUCCESS

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
        is connected via Bluetooth, falls back to vendor GATT battery key
        (when enabled), then BLE Battery Service.
        """
        request = self._create_report(CMD_CLASS_MISC, CMD_GET_BATTERY, 0x02)
        response = self._send_command(request)
        if response and response[0] == STATUS_SUCCESS and len(response) >= 10:
            charging = response[8] == 1
            level = int((response[9] / 255.0) * 100)
            return (level, charging)

        # BLE fallbacks for Bluetooth devices
        if self.vendor_id == BT_VENDOR_ID_RAZER:
            self._dbg("USB battery read failed, trying vendor battery key fallback")
            raw_level = self.get_battery_vendor_raw()
            if raw_level is not None:
                level = int((raw_level / 255.0) * 100)
                return (level, False)
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


def find_razer_mouse(debug_hid: bool = False, enable_vendor_gatt: bool = False) -> Optional[RazerMouse]:
    """Find and return a connected Bluetooth Razer mouse."""
    devices = hid.enumerate()

    # Group by VID:PID
    razer_devices = {}
    for d in devices:
        vid = d['vendor_id']
        pid = d['product_id']

        if vid == BT_VENDOR_ID_RAZER:
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
            print("Bluetooth device detected; using BLE/HID transport.\n")

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
                enable_vendor_gatt=enable_vendor_gatt,
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

    serial = mouse.get_serial()
    if serial:
        print(f"\n  Serial:         {serial}")

    fw = mouse.get_firmware()
    if fw:
        print(f"\n  Firmware:       v{fw[0]}.{fw[1]}")

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

    mode = mouse.get_device_mode()
    if mode is not None:
        mode_name = "driver" if mode[0] == 0x03 else "normal"
        print(f"\n  Device Mode:    {mode_name} ({mode[0]}:{mode[1]})")

    idle = mouse.get_idle_time()
    if idle is not None:
        print(f"\n  Idle Time:      {idle}s")

    low_batt = mouse.get_low_battery_threshold()
    if low_batt is not None:
        pct = int((low_batt / 255.0) * 100)
        print(f"\n  Low Battery:    raw {low_batt} (~{pct}%)")

    smode = mouse.get_scroll_mode()
    if smode is not None:
        smode_name = "freespin" if smode == 1 else "tactile"
        print(f"\n  Scroll Mode:    {smode_name} ({smode})")

    sacc = mouse.get_scroll_acceleration()
    if sacc is not None:
        print(f"\n  Scroll Accel:   {'on' if sacc else 'off'}")

    ssr = mouse.get_scroll_smart_reel()
    if ssr is not None:
        print(f"\n  Smart Reel:     {'on' if ssr else 'off'}")

    scroll_led = mouse.get_scroll_led_brightness()
    if scroll_led is not None:
        print(f"\n  Scroll LED:     brightness {scroll_led}/255")

    # Battery
    battery = mouse.get_battery()
    if battery:
        level, charging = battery
        status = " (charging)" if charging else ""
        print(f"\n  Battery:        {level}%{status}")

    if mouse.vendor_id == BT_VENDOR_ID_RAZER:
        power16 = mouse.get_power_timeout_raw()
        sleep8 = mouse.get_sleep_timeout_raw()
        light8 = mouse.get_lighting_value_raw()
        batt_raw = mouse.get_battery_vendor_raw()
        batt_status = mouse.get_battery_status_vendor_raw()
        if power16 is not None or sleep8 is not None or light8 is not None or batt_raw is not None or batt_status is not None:
            print("\n  BLE Raw:")
            if power16 is not None:
                print(f"    Power Timeout (u16): {power16} (0x{power16:04x})")
            if sleep8 is not None:
                print(f"    Sleep Timeout (u8):  {sleep8} (0x{sleep8:02x})")
            if light8 is not None:
                print(f"    Lighting Value (u8): {light8} (0x{light8:02x})")
            if batt_raw is not None:
                print(f"    Battery Raw (u8):    {batt_raw} (0x{batt_raw:02x})")
            if batt_status is not None:
                print(f"    Battery Status (u8): {batt_status} (0x{batt_status:02x})")

    print()


def _parse_rgb_hex(value: str) -> Optional[Tuple[int, int, int]]:
    s = (value or "").strip().lower().replace("#", "")
    if len(s) != 6:
        return None
    try:
        return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))
    except Exception:
        return None


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
  %(prog)s --single-dpi 1600            Use one fixed DPI stage
  %(prog)s --poll-rate 1000             Set polling rate to 1000 Hz

Note: This script targets Bluetooth transport.
        """
    )
    parser.add_argument('--dpi', type=int, metavar='DPI',
                        help='Set current DPI (100-30000)')
    parser.add_argument('--stages', type=str, metavar='DPI,DPI,...',
                        help='Set DPI stages (comma-separated, 1-5 values)')
    parser.add_argument('--active-stage', type=int, metavar='N',
                        help='Set active DPI stage (1-5)')
    parser.add_argument('--single-dpi', type=int, metavar='DPI',
                        help='Set single fixed DPI mode (1 stage)')
    parser.add_argument('--poll-rate', type=int, choices=[125, 500, 1000],
                        metavar='HZ', help='Set polling rate (125/500/1000 Hz)')
    parser.add_argument('--device-mode', choices=['normal', 'driver'],
                        help='Set device mode')
    parser.add_argument('--idle-time', type=int, metavar='SECONDS',
                        help='Set idle timeout seconds (60-900)')
    parser.add_argument('--low-battery-threshold', type=int, metavar='RAW',
                        help='Set low battery threshold raw value (0x0c-0x3f)')
    parser.add_argument('--scroll-mode', choices=['tactile', 'freespin'],
                        help='Set scroll wheel mode')
    parser.add_argument('--scroll-acceleration', choices=['on', 'off'],
                        help='Set scroll acceleration')
    parser.add_argument('--scroll-smart-reel', choices=['on', 'off'],
                        help='Set scroll smart reel')
    parser.add_argument('--scroll-led-brightness', type=int, metavar='0-255',
                        help='Set scroll wheel LED brightness')
    parser.add_argument('--scroll-led-effect', choices=['none', 'spectrum', 'wave-left', 'wave-right', 'breath-random'],
                        help='Set scroll wheel LED effect')
    parser.add_argument('--scroll-led-static', type=str, metavar='RRGGBB',
                        help='Set static scroll LED color (hex)')
    parser.add_argument('--scroll-led-reactive', type=str, metavar='SPEED:RRGGBB',
                        help='Set reactive scroll LED (speed 1-4)')
    parser.add_argument('--scroll-led-breath-single', type=str, metavar='RRGGBB',
                        help='Set breathing single-color scroll LED')
    parser.add_argument('--scroll-led-breath-dual', type=str, metavar='RRGGBB:RRGGBB',
                        help='Set breathing dual-color scroll LED')
    parser.add_argument('--usb-button-action', type=str, metavar='PROFILE:BTN:TYPE:PARAMHEX[:FN]',
                        help='Experimental USB button action write (class 0x02 id 0x0D)')
    parser.add_argument('--power-timeout-raw', type=int, metavar='N',
                        help='BLE raw u16 write (key 0504/0584)')
    parser.add_argument('--sleep-timeout-raw', type=int, metavar='N',
                        help='BLE raw u8 write (key 0502/0582)')
    parser.add_argument('--lighting-value-raw', type=int, metavar='N',
                        help='BLE raw u8 write (key 1005/1085)')
    parser.add_argument('--button-bind-raw', type=str, metavar='SLOT:HEX',
                        help='BLE raw button bind write (10-byte payload hex)')
    parser.add_argument('--button-default', type=int, metavar='SLOT',
                        help='Set button slot to default mouse action (capture-backed)')
    parser.add_argument('--button-mouse', type=str, metavar='SLOT:BTN',
                        help='Set button slot to mouse-button action (BTN id; 1=left, 2=right)')
    parser.add_argument('--button-left-click', type=int, metavar='SLOT',
                        help='Set button slot to left-click mouse action')
    parser.add_argument('--button-right-click', type=int, metavar='SLOT',
                        help='Set button slot to right-click mouse action')
    parser.add_argument('--button-keyboard', type=str, metavar='SLOT:KEY',
                        help='Set button slot to simple keyboard action (hid key code)')
    parser.add_argument('--button-keyboard-ext', type=str, metavar='SLOT:K1:K2',
                        help='Set button slot to extended keyboard action (capture-backed action 0x0d)')
    parser.add_argument('--button-action-u16', type=str, metavar='SLOT:TYPE:P0:P1:P2',
                        help='Generic action payload using 3x u16 params')
    parser.add_argument('--quiet', '-q', action='store_true',
                        help='Minimal output')
    parser.add_argument('--debug-hid', action='store_true',
                        help='Enable verbose HID transport debug output')
    parser.add_argument('--enable-vendor-gatt', action='store_true',
                        help='Enable BLE vendor GATT path (may be unstable on some macOS setups)')
    parser.add_argument('--battery-ble', action='store_true',
                        help='Read battery level via BLE Battery Service (macOS only)')
    parser.add_argument('--battery-vendor', action='store_true',
                        help='Read battery via BLE vendor keys (requires --enable-vendor-gatt)')
    parser.add_argument('--sniff-dpi', nargs='?', const=8.0, type=float, metavar='SECONDS',
                        help='Bluetooth: sniff passive DPI reports for N seconds (default: 8)')

    args = parser.parse_args()

    # Find mouse
    if not args.quiet:
        print("\nSearching for Razer mouse...")

    mouse = find_razer_mouse(debug_hid=args.debug_hid, enable_vendor_gatt=args.enable_vendor_gatt)

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

    if args.single_dpi:
        val = max(100, min(30000, int(args.single_dpi)))
        print(f"\nSetting single fixed DPI mode: {val}")
        if mouse.set_dpi_stages([val], 0):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    elif args.stages:
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

    if args.device_mode:
        mode = 0x03 if args.device_mode == "driver" else 0x00
        print(f"\nSetting device mode to: {args.device_mode}")
        if mouse.set_device_mode(mode, 0x00):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.idle_time is not None:
        print(f"\nSetting idle time to: {args.idle_time}s")
        if mouse.set_idle_time(args.idle_time):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.low_battery_threshold is not None:
        print(f"\nSetting low battery threshold raw to: {args.low_battery_threshold}")
        if mouse.set_low_battery_threshold(args.low_battery_threshold):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_mode:
        mode = 1 if args.scroll_mode == "freespin" else 0
        print(f"\nSetting scroll mode to: {args.scroll_mode}")
        if mouse.get_scroll_mode() is None:
            print("  Unsupported on this device/transport; skipping.")
            mode = None
        if mode is None:
            pass
        elif mouse.set_scroll_mode(mode):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_acceleration:
        enabled = args.scroll_acceleration == "on"
        print(f"\nSetting scroll acceleration: {args.scroll_acceleration}")
        if mouse.get_scroll_acceleration() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_acceleration(enabled):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_smart_reel:
        enabled = args.scroll_smart_reel == "on"
        print(f"\nSetting scroll smart reel: {args.scroll_smart_reel}")
        if mouse.get_scroll_smart_reel() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_smart_reel(enabled):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_led_brightness is not None:
        print(f"\nSetting scroll LED brightness to: {args.scroll_led_brightness}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_brightness(args.scroll_led_brightness):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_led_effect:
        print(f"\nSetting scroll LED effect to: {args.scroll_led_effect}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        else:
            ok = False
            if args.scroll_led_effect == "none":
                ok = mouse.set_scroll_led_effect_none()
            elif args.scroll_led_effect == "spectrum":
                ok = mouse.set_scroll_led_effect_spectrum()
            elif args.scroll_led_effect == "wave-left":
                ok = mouse.set_scroll_led_effect_wave(1)
            elif args.scroll_led_effect == "wave-right":
                ok = mouse.set_scroll_led_effect_wave(2)
            elif args.scroll_led_effect == "breath-random":
                ok = mouse.set_scroll_led_effect_breath_random()
            if ok:
                print("  Success!")
                made_changes = True
            else:
                print("  Failed!")
                return 1

    if args.scroll_led_static:
        rgb = _parse_rgb_hex(args.scroll_led_static)
        if rgb is None:
            print("\nInvalid --scroll-led-static; expected RRGGBB.")
            return 1
        print(f"\nSetting scroll LED static color to: #{args.scroll_led_static.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_static(*rgb):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_led_reactive:
        try:
            speed_s, rgb_s = args.scroll_led_reactive.split(':', 1)
            speed = int(speed_s, 0)
            rgb = _parse_rgb_hex(rgb_s)
            if rgb is None:
                raise ValueError("bad rgb")
        except Exception:
            print("\nInvalid --scroll-led-reactive; expected SPEED:RRGGBB.")
            return 1
        print(f"\nSetting scroll LED reactive effect speed={speed} color=#{rgb_s.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_reactive(speed, *rgb):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_led_breath_single:
        rgb = _parse_rgb_hex(args.scroll_led_breath_single)
        if rgb is None:
            print("\nInvalid --scroll-led-breath-single; expected RRGGBB.")
            return 1
        print(f"\nSetting scroll LED breathing single color to: #{args.scroll_led_breath_single.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_breath_single(*rgb):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.scroll_led_breath_dual:
        try:
            c1, c2 = args.scroll_led_breath_dual.split(':', 1)
            rgb1 = _parse_rgb_hex(c1)
            rgb2 = _parse_rgb_hex(c2)
            if rgb1 is None or rgb2 is None:
                raise ValueError("bad rgb")
        except Exception:
            print("\nInvalid --scroll-led-breath-dual; expected RRGGBB:RRGGBB.")
            return 1
        print(f"\nSetting scroll LED breathing dual colors to: #{c1.strip().lstrip('#')} and #{c2.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_breath_dual(*rgb1, *rgb2):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.usb_button_action:
        try:
            parts = args.usb_button_action.split(':')
            if len(parts) not in (4, 5):
                raise ValueError("bad part count")
            profile = int(parts[0], 0)
            button_id = int(parts[1], 0)
            action_type = int(parts[2], 0)
            param_bytes = bytes.fromhex(parts[3].strip()) if parts[3].strip() else b""
            fn_flag = bool(int(parts[4], 0)) if len(parts) == 5 else False
        except Exception:
            print("\nInvalid --usb-button-action format. Use PROFILE:BTN:TYPE:PARAMHEX[:FN].")
            return 1
        print(f"\nSetting USB button action profile={profile} button={button_id} type=0x{action_type:02x} params={param_bytes.hex()} fn={int(fn_flag)}")
        if mouse.set_usb_button_action(profile, button_id, action_type, param_bytes, fn_hypershift=fn_flag):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.power_timeout_raw is not None:
        val = max(0, min(0xFFFF, int(args.power_timeout_raw)))
        print(f"\nSetting BLE power-timeout raw to: {val} (0x{val:04x})")
        if mouse.set_power_timeout_raw(val):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.sleep_timeout_raw is not None:
        val = max(0, min(0xFF, int(args.sleep_timeout_raw)))
        print(f"\nSetting BLE sleep-timeout raw to: {val} (0x{val:02x})")
        if mouse.set_sleep_timeout_raw(val):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.lighting_value_raw is not None:
        val = max(0, min(0xFF, int(args.lighting_value_raw)))
        print(f"\nSetting BLE lighting raw value to: {val} (0x{val:02x})")
        if mouse.set_lighting_value_raw(val):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_bind_raw:
        try:
            slot_s, payload_hex = args.button_bind_raw.split(':', 1)
            slot = int(slot_s, 0)
            payload = bytes.fromhex(payload_hex.strip())
        except Exception:
            print("\nInvalid --button-bind-raw format. Use SLOT:HEX (10-byte hex payload).")
            return 1
        print(f"\nSetting raw button binding slot {slot} payload {payload.hex()}")
        if mouse.set_button_binding_raw(slot, payload):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_default is not None:
        slot = int(args.button_default)
        print(f"\nSetting button slot {slot} to default mouse action")
        if mouse.set_button_default(slot):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_mouse:
        try:
            slot_s, btn_s = args.button_mouse.split(':', 1)
            slot = int(slot_s, 0)
            btn = int(btn_s, 0)
        except Exception:
            print("\nInvalid --button-mouse format. Use SLOT:BTN.")
            return 1
        print(f"\nSetting button slot {slot} to mouse-button id {btn}")
        if mouse.set_button_mouse_button(slot, btn):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_left_click is not None:
        slot = int(args.button_left_click)
        print(f"\nSetting button slot {slot} to left-click action")
        if mouse.set_button_left_click(slot):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_right_click is not None:
        slot = int(args.button_right_click)
        print(f"\nSetting button slot {slot} to right-click action")
        if mouse.set_button_right_click(slot):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_keyboard:
        try:
            slot_s, key_s = args.button_keyboard.split(':', 1)
            slot = int(slot_s, 0)
            hid_key = int(key_s, 0)
        except Exception:
            print("\nInvalid --button-keyboard format. Use SLOT:KEY.")
            return 1
        print(f"\nSetting button slot {slot} to keyboard HID key 0x{hid_key:02x}")
        if mouse.set_button_keyboard_simple(slot, hid_key):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_keyboard_ext:
        try:
            slot_s, k1_s, k2_s = args.button_keyboard_ext.split(':', 2)
            slot = int(slot_s, 0)
            k1 = int(k1_s, 0)
            k2 = int(k2_s, 0)
        except Exception:
            print("\nInvalid --button-keyboard-ext format. Use SLOT:K1:K2.")
            return 1
        print(f"\nSetting button slot {slot} to extended keyboard action ({k1:#06x}, {k2:#06x})")
        if mouse.set_button_keyboard_extended(slot, k1, k2):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1

    if args.button_action_u16:
        try:
            slot_s, typ_s, p0_s, p1_s, p2_s = args.button_action_u16.split(':', 4)
            slot = int(slot_s, 0)
            typ = int(typ_s, 0)
            p0 = int(p0_s, 0)
            p1 = int(p1_s, 0)
            p2 = int(p2_s, 0)
        except Exception:
            print("\nInvalid --button-action-u16 format. Use SLOT:TYPE:P0:P1:P2.")
            return 1
        print(f"\nSetting button slot {slot} action=0x{typ:02x} params=({p0:#06x},{p1:#06x},{p2:#06x})")
        if mouse.set_button_action_u16(slot, typ, p0, p1, p2):
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

    if args.battery_vendor:
        print("\nReading battery via BLE vendor keys...")
        raw = mouse.get_battery_vendor_raw()
        status = mouse.get_battery_status_vendor_raw()
        if raw is not None:
            pct = int((raw / 255.0) * 100)
            print(f"  Battery (vendor raw): {raw} (0x{raw:02x}) ~{pct}%")
        else:
            print("  Could not read vendor battery raw key.")
            print("  Try again with --enable-vendor-gatt.")
        if status is not None:
            print(f"  Battery status (vendor raw): {status} (0x{status:02x})")

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
