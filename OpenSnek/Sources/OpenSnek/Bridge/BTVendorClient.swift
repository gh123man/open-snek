import Foundation
import CoreBluetooth
import OpenSnekHardware
import OpenSnekProtocols

final class BTVendorClient: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "open.snek.bt.vendor")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var notifications: [Data] = []
    private var writeQueue: [Data] = []
    private var completion: ((Result<[Data], any Error>) -> Void)?
    private var finishWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?
    private var isNotifyReady = false

    func run(writes: [Data], timeout: TimeInterval = 2.2) async throws -> [Data] {
        let start = Date()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Data], any Error>) in
            queue.async {
                guard self.completion == nil else {
                    AppLog.error("BTVendor", "run rejected busy writes=\(writes.count)")
                    continuation.resume(throwing: BridgeError.commandFailed("BT vendor busy"))
                    return
                }
                AppLog.debug("BTVendor", "run start writes=\(writes.count) timeout=\(String(format: "%.2f", timeout))s")
                self.notifications = []
                self.writeQueue = writes
                self.finishWorkItem?.cancel()
                self.finishWorkItem = nil
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil

                self.completion = { output in
                    AppLog.debug("BTVendor", "run finish elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
                    continuation.resume(with: output)
                }

                if self.central == nil {
                    self.central = CBCentralManager(delegate: self, queue: self.queue)
                } else {
                    self.ensureConnectedAndReady()
                }

                let timeoutItem = DispatchWorkItem { [weak self] in
                    AppLog.error("BTVendor", "run timeout")
                    self?.finish(.failure(BridgeError.commandFailed("BT vendor timeout")))
                }
                self.timeoutWorkItem = timeoutItem
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            }
        }
    }

    private func sendNextWriteIfReady() {
        guard isNotifyReady, let peripheral, let writeChar, !writeQueue.isEmpty else {
            scheduleFinishIfIdle()
            return
        }

        finishWorkItem?.cancel()
        let next = writeQueue.removeFirst()
        peripheral.writeValue(next, for: writeChar, type: .withResponse)
    }

    private func scheduleFinishIfIdle() {
        guard writeQueue.isEmpty else { return }
        finishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.success(self.notifications))
        }
        finishWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func fail(_ message: String) {
        AppLog.error("BTVendor", message)
        finish(.failure(BridgeError.commandFailed("BT vendor: \(message)")))
    }

    private func ensureConnectedAndReady() {
        guard let central else { return }
        guard central.state == .poweredOn else { return }

        if isNotifyReady, peripheral?.state == .connected, writeChar != nil, notifyChar != nil {
            sendNextWriteIfReady()
            return
        }

        let peripherals = central.retrieveConnectedPeripherals(withServices: [CBUUID(nsuuid: BLEVendorProtocol.serviceUUID)])
        guard let connected = peripherals.first else {
            // CoreBluetooth can transiently return an empty set right after reconnects.
            // Keep retrying within the run timeout window instead of failing immediately.
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.completion != nil else { return }
                self.ensureConnectedAndReady()
            }
            return
        }

        peripheral = connected
        connected.delegate = self
        if connected.state == .connected {
            connected.discoverServices([CBUUID(nsuuid: BLEVendorProtocol.serviceUUID)])
        } else {
            central.connect(connected)
        }
    }

    private func finish(_ output: Result<[Data], Error>) {
        guard let completion else { return }
        self.completion = nil
        finishWorkItem?.cancel()
        finishWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        completion(output)
    }
}

extension BTVendorClient: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            ensureConnectedAndReady()
        case .unauthorized:
            fail("Bluetooth access unauthorized; allow Open Snek in System Settings > Privacy & Security > Bluetooth")
        case .poweredOff:
            fail("Bluetooth is powered off")
        case .unsupported:
            fail("Bluetooth is unsupported on this Mac")
        case .resetting, .unknown:
            // Keep waiting inside the current run timeout window.
            break
        @unknown default:
            fail("Bluetooth state is unsupported")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(nsuuid: BLEVendorProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isNotifyReady = false
        fail("Failed to connect: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isNotifyReady = false
        writeChar = nil
        notifyChar = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail("Service discovery failed: \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            fail("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(nsuuid: BLEVendorProtocol.writeUUID) {
                writeChar = characteristic
            }
            if characteristic.uuid == CBUUID(nsuuid: BLEVendorProtocol.notifyUUID) {
                notifyChar = characteristic
            }
        }

        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Enable notify failed: \(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            isNotifyReady = true
            sendNextWriteIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Write failed: \(error.localizedDescription)")
            return
        }
        sendNextWriteIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Notify update failed: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        notifications.append(value)
    }
}
