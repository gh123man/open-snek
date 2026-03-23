import threading
import time
from typing import List, Optional, Tuple

try:
    import objc
    from CoreBluetooth import CBCentralManager, CBUUID
    from Foundation import NSDate, NSData, NSObject, NSRunLoop

    HAS_CB_VENDOR = True
except Exception:
    HAS_CB_VENDOR = False


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
        def __init__(self, service_uuid: str, write_uuid: str, notify_uuid: str, debug: bool = False):
            self.service_uuid = service_uuid
            self.write_uuid = write_uuid
            self.notify_uuid = notify_uuid
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
            uuid = CBUUID.UUIDWithString_(self.service_uuid)
            peripherals = central.retrieveConnectedPeripheralsWithServices_([uuid])
            if not peripherals:
                self._on_error("no connected Razer vendor-service peripheral")
                return
            self.peripheral = peripherals[0]
            self.peripheral.setDelegate_(self._delegate)
            central.connectPeripheral_options_(self.peripheral, None)

        def _on_connected(self, peripheral):
            uuid = CBUUID.UUIDWithString_(self.service_uuid)
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
                if uuid == self.write_uuid:
                    self.write_char = ch
                elif uuid == self.notify_uuid:
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
