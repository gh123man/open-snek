# Razer Protocol Documentation Index

The USB and BLE protocols are related at the **setting semantics** level (DPI stages, battery, poll-related fields), but they use **different transport and framing**:

- USB/dongle: 90-byte HID feature report protocol
- BLE: vendor GATT request/notify protocol (`...1524` / `...1525`) with different packet structure

For clarity, documentation is now split:

- [USB Protocol](./USB_PROTOCOL.md)
- [BLE Protocol Spec](./BLE_PROTOCOL.md)
- [USB/BLE Parity](./PARITY.md)
- [BLE Reverse Engineering Notes](../research/BLE_REVERSE_ENGINEERING.md)
- [OpenSnek App/Probe Guide](../../OpenSnek/README.md)

Agent fast-path:
- USB-only change: open `USB_PROTOCOL.md`
- BLE-only change: open `BLE_PROTOCOL.md`
- support matrix / shipped-status change: open `PARITY.md`
- reverse-engineering context only when needed: open `BLE_REVERSE_ENGINEERING.md`
