# Windows Bluetooth Capture Runbook

## Purpose

Capture the exact BLE GATT writes Razer Synapse sends when changing DPI over Bluetooth on a Basilisk V3 X HyperSpeed mouse. We need the raw payloads before BLE encryption so we can replay them from macOS/Linux.

## Background (What We Know)

From exhaustive macOS testing:

| Fact | Detail |
|------|--------|
| Device | Razer Basilisk V3 X HyperSpeed |
| BT VID:PID | `068e:00BA` |
| USB VID:PID | `1532:00B9` |
| Vendor GATT Service | `52401523-F97C-7F90-0E7F-6C6F4E36DB1C` |
| Write Characteristic | `52401524-F97C-7F90-0E7F-6C6F4E36DB1C` (write-with-response) |
| Notify Characteristic | `52401525-F97C-7F90-0E7F-6C6F4E36DB1C` (read, notify) |
| Notify2 Characteristic | `52401526-F97C-7F90-0E7F-6C6F4E36DB1C` (read, notify) |
| HID Service | `0x1812` (macOS claims it exclusively) |
| Lighting protocol | Two-write pair: 8-byte init `130a000010030000` + 10-byte effect payload |
| DPI passive read | HID input report `05 05 02 XX XX YY YY 00 00` (big-endian DPI X, DPI Y) |
| DPI write via GATT | **NOT possible** — vendor GATT appears lighting-only on this mouse |
| DPI write via HID | **NOT possible on macOS** — BLE HID descriptor has zero Feature/Output reports |
| USB 90-byte protocol | Works over USB cable/dongle but NOT over BLE |

**Key question**: Does Synapse use a different transport for DPI writes over BT? Options:
1. The vendor GATT service with a payload format we haven't discovered
2. The HID service (0x1812) with Feature/Output reports that Windows exposes but macOS blocks
3. A completely different BLE characteristic or service
4. Synapse doesn't actually write DPI over BT (routes through cloud/dongle)

---

## Prerequisites

### Hardware
- Windows 10/11 PC with Bluetooth (built-in or USB BT adapter)
- Razer Basilisk V3 X HyperSpeed mouse paired via Bluetooth (NOT dongle, NOT USB cable)
- Confirm Synapse can change DPI while mouse is on BT (if it can't, that answers our question)

### Software to Install

All tools are CLI-installable. Run in an **Administrator PowerShell**:

```powershell
# 1. Python 3.10+ (from python.org or winget)
winget install Python.Python.3.12

# 2. Frida (for hooking Windows BLE APIs)
pip install frida-tools frida

# 3. Wireshark + USBPcap (for optional HID-level capture)
winget install WiresharkFoundation.Wireshark

# 4. BLE logging via Windows built-in ETW (Event Tracing for Windows)
#    No install needed — uses built-in logman.exe and netsh.exe

# 5. Optional: npcap for Wireshark network capture
winget install Npcap.Npcap

# 6. Python BLE library for replay validation
pip install bleak
```

### Verify Mouse is on Bluetooth
```powershell
# List paired BT devices
Get-PnpDevice -Class Bluetooth | Where-Object { $_.FriendlyName -like "*Razer*" -or $_.FriendlyName -like "*Basilisk*" -or $_.FriendlyName -like "*BSK*" }

# Confirm Synapse sees the device
# Open Razer Synapse, verify the mouse appears and DPI slider works
```

---

## Capture Method 1: Windows BLE ETW Tracing (Start Here)

Windows logs all BLE GATT operations via ETW (Event Tracing for Windows). This captures **pre-encryption** payloads including characteristic UUIDs, handles, and data bytes.

### Step 1: Start BLE ETW Trace

```powershell
# Start Bluetooth ETW log capture
# Microsoft-Windows-Bluetooth-BthLEPrePairing and related providers
logman create trace BLECapture -ow -o C:\BLECapture.etl -p "Microsoft-Windows-Bluetooth-Device" 0xFFFFFFFF 0xFF
logman update trace BLECapture -p "{8a4f0ac1-0f32-4b5b-ba73-96e3f367d5d9}" 0xFFFFFFFF 0xFF
logman start BLECapture
```

Alternative using the Bluetooth HCI log (captures ALL BLE traffic at the HCI level):

```powershell
# Enable Bluetooth HCI logging (built into Windows)
# This produces a .etl file with full HCI packets including GATT writes
reg add "HKLM\SYSTEM\CurrentControlSet\Services\BthLEEnum\Parameters" /v "BluetoothDebug" /t REG_DWORD /d 1 /f

# Start the BTH ETW session
logman create trace BTHCapture -ow -o C:\BTHCapture.etl -p "{8a4f0ac1-0f32-4b5b-ba73-96e3f367d5d9}" 0xFFFFFFFF 0xFF -p "Microsoft-Windows-Bluetooth-BthLEEnum" 0xFFFFFFFF 0xFF -p "Microsoft-Windows-Bluetooth-MtpEnum" 0xFFFFFFFF 0xFF
logman start BTHCapture
```

### Step 2: Perform Controlled DPI Change

Do exactly ONE change per capture session:

```
Experiment A: DPI 800 → 1600
  1. Open Synapse
  2. Wait 30 seconds (baseline)
  3. Change DPI from 800 to 1600
  4. Wait 10 seconds
  5. Stop capture

Experiment B: DPI 1600 → 3200
  Same procedure, different values

Experiment C: DPI stage switch (press DPI button on mouse)
  Capture the passive HID report for comparison
```

### Step 3: Stop and Convert Trace

```powershell
logman stop BTHCapture
logman delete BTHCapture

# Convert .etl to text for analysis
netsh trace convert input=C:\BTHCapture.etl output=C:\BTHCapture.txt

# Or use Microsoft Message Analyzer / Wireshark to open the .etl directly
# Wireshark can open BTSnoop-format logs but ETL needs conversion first

# Alternative: use Microsoft's BETLParse or btsnoop converter
# pip install btsnoop
# python -c "import btsnoop; btsnoop.parse('C:\\BTHCapture.etl')"
```

### Step 4: Filter for GATT Writes

Search the trace output for:
- ATT Write Request / Write Command opcodes (`0x12` = Write Request, `0x52` = Write Command)
- The vendor service handle range
- Any writes to characteristics outside the known vendor service
- Our known UUIDs: `52401524` (write), `52401525` (notify1), `52401526` (notify2)
- HID service UUID `1812` and any Feature Report characteristic writes

```powershell
# Quick text search in converted trace
Select-String -Path C:\BTHCapture.txt -Pattern "52401524|52401525|1812|Write|0x12|0x52" | Out-File C:\filtered_writes.txt
```

---

## Capture Method 2: Frida Hook on Synapse BLE Calls (Most Precise)

Hook the Windows Runtime BLE APIs that Synapse uses. This captures the exact characteristic UUID + payload for each write.

### Step 1: Identify Synapse Processes

```powershell
# Synapse runs multiple processes. Find them all:
Get-Process | Where-Object { $_.ProcessName -like "*Razer*" -or $_.ProcessName -like "*Synapse*" } | Format-Table Id, ProcessName, Path

# Common process names:
#   RazerSynapse.exe (main UI)
#   Razer Synapse Service.exe (background service)
#   RazerCentralService.exe
#   GameManagerService.exe
#
# The SERVICE process is most likely to handle BLE writes (not the UI)
```

### Step 2: Frida Script for WinRT BLE API Hooks

Save this as `capture_ble_writes.js`:

```javascript
/*
 * Frida script to hook Windows Runtime Bluetooth LE GATT write operations.
 *
 * Target APIs:
 *   Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristic
 *     - WriteValueAsync(IBuffer)
 *     - WriteValueWithResultAsync(IBuffer)
 *     - WriteValueWithResultAndOptionAsync(IBuffer, GattWriteOption)
 *
 * Also hooks notification subscriptions:
 *   - WriteClientCharacteristicConfigurationDescriptorAsync
 *   - ValueChanged event registration
 */

'use strict';

// Log helper
function log(msg) {
    var ts = new Date().toISOString();
    send({ type: 'log', ts: ts, msg: msg });
    console.log('[' + ts + '] ' + msg);
}

function bufferToHex(bufPtr, length) {
    if (!bufPtr || length <= 0) return '';
    try {
        var bytes = [];
        for (var i = 0; i < length; i++) {
            bytes.push(('0' + bufPtr.add(i).readU8().toString(16)).slice(-2));
        }
        return bytes.join(' ');
    } catch (e) {
        return '<read error: ' + e + '>';
    }
}

// Hook DeviceIoControl - this is the lowest-level syscall for BLE GATT writes
// on Windows. All WinRT BLE calls eventually go through here.
var kernel32 = Module.findBaseAddress('kernel32.dll');
var deviceIoControl = Module.findExportByName('kernel32.dll', 'DeviceIoControl');

if (deviceIoControl) {
    Interceptor.attach(deviceIoControl, {
        onEnter: function(args) {
            // DeviceIoControl(hDevice, dwIoControlCode, lpInBuffer, nInBufferSize,
            //                 lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped)
            var ioctl = args[1].toInt32() >>> 0;
            var inSize = args[3].toInt32();

            // IOCTL_BTH_LE_WRITE_CHARACTERISTIC_VALUE = 0x411008
            // IOCTL_BTH_LE_SET_CHARACTERISTIC_VALUE = 0x41100C
            // BLE-related IOCTLs are in the 0x41XXXX range
            if ((ioctl & 0xFF0000) === 0x410000 && inSize > 0) {
                this.ioctl = ioctl;
                this.inBuf = args[2];
                this.inSize = inSize;
            }
        },
        onLeave: function(retval) {
            if (this.ioctl) {
                var hex = bufferToHex(this.inBuf, Math.min(this.inSize, 128));
                log('DeviceIoControl IOCTL=0x' + this.ioctl.toString(16) +
                    ' size=' + this.inSize + ' data=[' + hex + ']');
            }
        }
    });
    log('Hooked DeviceIoControl for BLE IOCTLs');
}

// Also hook BluetoothGATTSetCharacteristicValue (bluetoothapis.dll)
var btApis = Module.findBaseAddress('bluetoothapis.dll');
if (btApis) {
    var setCharValue = Module.findExportByName('bluetoothapis.dll',
        'BluetoothGATTSetCharacteristicValue');
    if (setCharValue) {
        Interceptor.attach(setCharValue, {
            onEnter: function(args) {
                // BluetoothGATTSetCharacteristicValue(
                //   hDevice, characteristic, characteristicValue, reliableWriteContext, flags)
                var charPtr = args[1];
                var valuePtr = args[2];
                log('BluetoothGATTSetCharacteristicValue called');
                if (valuePtr) {
                    // BTH_LE_GATT_CHARACTERISTIC_VALUE struct:
                    //   ULONG DataSize at offset 0
                    //   UCHAR Data[] at offset 4
                    try {
                        var dataSize = valuePtr.readU32();
                        var dataHex = bufferToHex(valuePtr.add(4), Math.min(dataSize, 128));
                        log('  GATT Write: size=' + dataSize + ' payload=[' + dataHex + ']');
                    } catch(e) {
                        log('  GATT Write: parse error: ' + e);
                    }
                }
                if (charPtr) {
                    // BTH_LE_GATT_CHARACTERISTIC struct contains UUID at various offsets
                    try {
                        var attrHandle = charPtr.add(0).readU16();
                        var charUuidType = charPtr.add(2).readU16();
                        log('  Char handle=0x' + attrHandle.toString(16) +
                            ' uuidType=' + charUuidType);
                        // Dump first 48 bytes of characteristic struct for analysis
                        var structHex = bufferToHex(charPtr, 48);
                        log('  Char struct=[' + structHex + ']');
                    } catch(e) {
                        log('  Char struct parse error: ' + e);
                    }
                }
            },
            onLeave: function(retval) {
                log('  GATT Write returned: ' + retval);
            }
        });
        log('Hooked BluetoothGATTSetCharacteristicValue');
    }

    // Hook BluetoothGATTGetCharacteristicValue (for reads)
    var getCharValue = Module.findExportByName('bluetoothapis.dll',
        'BluetoothGATTGetCharacteristicValue');
    if (getCharValue) {
        Interceptor.attach(getCharValue, {
            onEnter: function(args) {
                this.valuePtr = args[2];
                this.sizePtr = args[3];
                log('BluetoothGATTGetCharacteristicValue called');
            },
            onLeave: function(retval) {
                if (retval.toInt32() === 0 && this.valuePtr) {
                    try {
                        var dataSize = this.valuePtr.readU32();
                        var dataHex = bufferToHex(this.valuePtr.add(4), Math.min(dataSize, 128));
                        log('  GATT Read result: size=' + dataSize + ' data=[' + dataHex + ']');
                    } catch(e) {}
                }
            }
        });
        log('Hooked BluetoothGATTGetCharacteristicValue');
    }

    // Hook BluetoothGATTRegisterEvent (for notification subscriptions)
    var regEvent = Module.findExportByName('bluetoothapis.dll',
        'BluetoothGATTRegisterEvent');
    if (regEvent) {
        Interceptor.attach(regEvent, {
            onEnter: function(args) {
                log('BluetoothGATTRegisterEvent called (notification subscribe)');
                try {
                    var structHex = bufferToHex(args[1], 48);
                    log('  EventParam struct=[' + structHex + ']');
                } catch(e) {}
            }
        });
        log('Hooked BluetoothGATTRegisterEvent');
    }
} else {
    log('WARNING: bluetoothapis.dll not loaded in this process');
}

// Hook HID writes too (in case Synapse uses HID Feature Reports over BT)
var hid = Module.findBaseAddress('hid.dll');
if (hid) {
    var hidSetFeature = Module.findExportByName('hid.dll', 'HidD_SetFeature');
    if (hidSetFeature) {
        Interceptor.attach(hidSetFeature, {
            onEnter: function(args) {
                var bufSize = args[2].toInt32();
                var hex = bufferToHex(args[1], Math.min(bufSize, 128));
                log('HidD_SetFeature size=' + bufSize + ' data=[' + hex + ']');
            },
            onLeave: function(retval) {
                log('  HidD_SetFeature returned: ' + retval);
            }
        });
        log('Hooked HidD_SetFeature');
    }

    var hidSetOutput = Module.findExportByName('hid.dll', 'HidD_SetOutputReport');
    if (hidSetOutput) {
        Interceptor.attach(hidSetOutput, {
            onEnter: function(args) {
                var bufSize = args[2].toInt32();
                var hex = bufferToHex(args[1], Math.min(bufSize, 128));
                log('HidD_SetOutputReport size=' + bufSize + ' data=[' + hex + ']');
            },
            onLeave: function(retval) {
                log('  HidD_SetOutputReport returned: ' + retval);
            }
        });
        log('Hooked HidD_SetOutputReport');
    }

    var hidGetFeature = Module.findExportByName('hid.dll', 'HidD_GetFeature');
    if (hidGetFeature) {
        Interceptor.attach(hidGetFeature, {
            onEnter: function(args) {
                this.buf = args[1];
                this.size = args[2].toInt32();
            },
            onLeave: function(retval) {
                if (retval.toInt32() !== 0) {
                    var hex = bufferToHex(this.buf, Math.min(this.size, 128));
                    log('HidD_GetFeature size=' + this.size + ' data=[' + hex + ']');
                }
            }
        });
        log('Hooked HidD_GetFeature');
    }
} else {
    log('WARNING: hid.dll not loaded in this process');
}

log('=== Frida BLE capture script loaded ===');
log('Waiting for GATT writes and HID operations...');
```

### Step 3: Run Frida Against Synapse Processes

```powershell
# Save the script above as C:\capture_ble_writes.js

# Find all Razer processes
$procs = Get-Process | Where-Object { $_.ProcessName -like "*Razer*" -or $_.ProcessName -like "*Synapse*" }
$procs | Format-Table Id, ProcessName

# Attach to EACH Razer process and log output
# Run each in a separate PowerShell window/tab:
foreach ($p in $procs) {
    $logFile = "C:\frida_$($p.ProcessName)_$($p.Id).log"
    Write-Host "Attaching to $($p.ProcessName) (PID $($p.Id)) -> $logFile"
    Start-Process -NoNewWindow powershell -ArgumentList "-Command", "frida -p $($p.Id) -l C:\capture_ble_writes.js 2>&1 | Tee-Object -FilePath $logFile"
}
```

Or attach to a single process:

```powershell
# Find the most likely service process
$svc = Get-Process | Where-Object { $_.ProcessName -like "*RazerCentral*" -or $_.ProcessName -like "*Synapse*Service*" } | Select-Object -First 1
frida -p $svc.Id -l C:\capture_ble_writes.js 2>&1 | Tee-Object -FilePath C:\frida_ble_capture.log
```

### Step 4: Trigger DPI Change and Collect Logs

While Frida is attached:
1. Wait 30 seconds (baseline — note any periodic writes)
2. In Synapse UI, change DPI from 800 to 1600
3. Wait 10 seconds
4. Stop Frida (Ctrl+C)

Repeat with DPI 1600 → 3200 for a second capture.

---

## Capture Method 3: Wireshark USB HID Capture (Fallback)

If Synapse routes BT config through a USB HID bridge (e.g., the dongle), capture USB HID traffic.

```powershell
# Install USBPcap during Wireshark install (check the option)
# Then capture USB traffic:

# List USB devices
USBPcapCMD.exe --list

# Start capture on the bus where the Razer dongle/BT adapter is:
USBPcapCMD.exe -d "\\.\USBPcap1" -o C:\usb_capture.pcapng

# In Wireshark, filter:
#   usb.idVendor == 0x1532 || usb.idVendor == 0x068e
#   usb.transfer_type == 0x02 (Control)
```

---

## Capture Method 4: Python bleak Direct GATT Enumeration

Before even capturing Synapse, check what GATT services Windows exposes:

```python
"""Enumerate all GATT services/characteristics on the Razer mouse from Windows."""
import asyncio
from bleak import BleakScanner, BleakClient

async def main():
    print("Scanning for Razer BLE devices...")
    devices = await BleakScanner.discover(timeout=10.0)

    razer = None
    for d in devices:
        name = d.name or ""
        if any(kw in name.lower() for kw in ['razer', 'basilisk', 'bsk']):
            razer = d
            print(f"Found: {d.name} ({d.address})")
            break

    if not razer:
        # Try paired devices (Windows may hide them from scans too)
        print("No Razer in scan. Try providing address directly.")
        return

    async with BleakClient(razer) as client:
        print(f"\nConnected: {client.is_connected}")
        print(f"\nGATT Services:")
        for service in client.services:
            print(f"\n  Service: {service.uuid} — {service.description}")
            for char in service.characteristics:
                props = ", ".join(char.properties)
                print(f"    Char: {char.uuid} [{props}]")
                # Try reading readable chars
                if "read" in char.properties:
                    try:
                        val = await client.read_gatt_char(char)
                        print(f"      Value: {val.hex()}")
                    except Exception as e:
                        print(f"      Read error: {e}")

asyncio.run(main())
```

**Key question this answers**: Does Windows expose MORE GATT services/characteristics than macOS? Specifically, does the HID service (0x1812) show Feature/Output report characteristics?

---

## Analysis Procedure

### What to Look For in Captured Data

1. **GATT writes to `52401524`** (vendor write char):
   - Compare payload format to our known 8+10 byte init+payload pattern
   - Look for NEW init mode bytes (we tested 10/00-10/0F; Synapse may use others)
   - DPI values should appear as big-endian 16-bit: `0x0320`=800, `0x0640`=1600, `0x0C80`=3200

2. **GATT writes to any HID-related characteristic**:
   - If Synapse writes to the HID service, capture the characteristic UUID + data
   - Look for 90-byte payloads (USB HID Feature Report format)
   - Or shorter payloads with embedded DPI values

3. **HID Feature Report writes** (via `HidD_SetFeature`):
   - If Synapse uses the Windows HID stack instead of raw GATT
   - Look for 90-byte buffers matching the USB protocol format
   - Report ID should be in byte 0

4. **Notification payloads on `52401525`/`52401526`**:
   - Responses to writes that include DPI status
   - Compare to our known response format: `[echo] 00 00 00 00 00 00 [status] [token]`

### Diff Template

For each experiment, produce this diff:

```
Experiment: DPI 800 -> 1600
Timestamp: <when>
Transport: <GATT write / HID Feature / HID Output / other>
Target: <characteristic UUID or HID report ID>

Writes observed (in order):
  1. <hex payload>  (write-with-response / write-command)
  2. <hex payload>

Notifications received:
  1. <hex payload> on <characteristic UUID>

Bytes that changed vs baseline:
  Offset X: 0x03 -> 0x06 (DPI high byte: 800=0x0320, 1600=0x0640)
  Offset Y: 0x20 -> 0x40 (DPI low byte)
```

---

## Replay Validation

After identifying the write payload, validate on the Windows machine:

```python
"""Replay a captured BLE GATT write to validate it changes DPI."""
import asyncio
import sys
from bleak import BleakClient

DEVICE_ADDRESS = "<paste address from scan>"
WRITE_CHAR = "52401524-f97c-7f90-0e7f-6c6f4e36db1c"
NOTIFY_CHAR = "52401525-f97c-7f90-0e7f-6c6f4e36db1c"

async def main():
    # Paste captured payload hex here
    init_payload = bytes.fromhex(sys.argv[1])    # e.g., "130a000010030000"
    data_payload = bytes.fromhex(sys.argv[2])    # e.g., the DPI write payload

    responses = []

    def on_notify(sender, data):
        status = data[7] if len(data) >= 8 else -1
        smap = {0x02: "OK", 0x03: "ERR", 0x05: "PERR"}
        print(f"  NOTIFY [{smap.get(status, hex(status))}]: {data.hex()}")
        responses.append(data)

    async with BleakClient(DEVICE_ADDRESS) as client:
        print(f"Connected: {client.is_connected}")

        await client.start_notify(NOTIFY_CHAR, on_notify)
        await asyncio.sleep(1)

        print(f"Writing init:    {init_payload.hex()}")
        await client.write_gatt_char(WRITE_CHAR, init_payload, response=True)
        await asyncio.sleep(0.3)

        print(f"Writing payload: {data_payload.hex()}")
        await client.write_gatt_char(WRITE_CHAR, data_payload, response=True)
        await asyncio.sleep(2)

        await client.stop_notify(NOTIFY_CHAR)

    print(f"\nResponses: {len(responses)}")

# Usage: python replay.py "130a000010030000" "CAPTURED_PAYLOAD_HEX"
asyncio.run(main())
```

---

## Deliverables

After completing the capture, provide:

1. **Transport identification**: Which API/characteristic Synapse uses for DPI writes over BT
2. **Raw payload hex** for at least:
   - DPI 800 → 1600 write
   - DPI 1600 → 3200 write
   - Any init/handshake sequence that precedes the DPI write
3. **Notification/response hex** correlated to each write
4. **Characteristic UUID** and write mode (with-response vs without-response)
5. **Full Frida log** or ETW trace file for independent analysis
6. **Whether Synapse uses GATT or HID** for the DPI write (this is the single most important question)
7. **GATT service enumeration** from Windows (does Windows expose more services than macOS?)

### Output Format

Produce a JSON file `bt_capture_results.json`:

```json
{
  "device": "Basilisk V3 X HyperSpeed",
  "device_address": "<BT address>",
  "transport": "GATT|HID_FEATURE|HID_OUTPUT|OTHER",
  "service_uuid": "<if GATT>",
  "write_char_uuid": "<if GATT>",
  "notify_char_uuid": "<if GATT>",
  "write_mode": "with_response|without_response",
  "commands": [
    {
      "operation": "set_dpi",
      "dpi_before": 800,
      "dpi_after": 1600,
      "writes": [
        {"hex": "130a000010030000", "label": "init"},
        {"hex": "<payload hex>", "label": "dpi_write"}
      ],
      "notifications": [
        {"hex": "<response hex>", "char_uuid": "<uuid>"}
      ]
    }
  ],
  "gatt_services": [
    {
      "uuid": "<service uuid>",
      "characteristics": [
        {"uuid": "<char uuid>", "properties": ["read", "write", "notify"]}
      ]
    }
  ]
}
```

---

## Quick Reference: Known Protocol Values

```
USB SET_DPI_XY (90-byte HID Feature Report):
  Byte 0:  0x00 (status: new)
  Byte 1:  0x1F (transaction ID for this device)
  Byte 5:  0x07 (data size)
  Byte 6:  0x04 (command class: DPI)
  Byte 7:  0x05 (command ID: SET_DPI_XY)
  Byte 8:  0x00 (NOSTORE) or 0x01 (VARSTORE)
  Byte 9-10: DPI X big-endian
  Byte 11-12: DPI Y big-endian
  Byte 88: XOR checksum of bytes 2-87

DPI values (big-endian):
  400  = 0x0190
  800  = 0x0320
  1600 = 0x0640
  3200 = 0x0C80
  6400 = 0x1900

Vendor GATT init (8 bytes, known working for lighting):
  13 0a 00 00 10 03 00 00

Vendor GATT lighting payloads (10 bytes):
  Static:   01 00 00 01 RR GG BB 00 00 00
  Breathe:  02 00 00 01 RR GG BB 00 00 00
  Spectrum: 03 00 00 00 00 00 00 00 00 00
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Frida can't attach to Synapse | Run PowerShell as Administrator. Synapse services run as SYSTEM. Try `frida -H 127.0.0.1 -p <PID>` or use `frida-server`. |
| No GATT writes in Frida log | Synapse may use HID, not GATT. Check `HidD_SetFeature` hooks. Also try attaching to ALL Razer processes, not just one. |
| `bluetoothapis.dll` not loaded | The process doesn't use the Win32 BLE API. Try WinRT hooks instead, or switch to ETW capture. |
| bleak can't find device | Paired BLE HID devices may be hidden from scans on Windows too. Use `BleakClient(address)` directly with the known address from `Get-PnpDevice`. |
| Synapse can't change DPI on BT | This IS a valid finding — means DPI write over BT may not be supported for this device, confirming our macOS results. |
| ETW trace is empty | Ensure Bluetooth debugging is enabled: `reg add "HKLM\SYSTEM\CurrentControlSet\Services\BthLEEnum\Parameters" /v "BluetoothDebug" /t REG_DWORD /d 1 /f` and restart Bluetooth service. |
