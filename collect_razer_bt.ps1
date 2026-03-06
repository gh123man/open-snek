# collect_razer_bt.ps1 - Collect Razer BLE mouse driver/device data for reverse engineering
# Run as Administrator for full access to registry and driver files
#
# Usage: powershell -ExecutionPolicy Bypass -File collect_razer_bt.ps1
# Output: creates razer_bt_dump/ directory with all collected data

$ErrorActionPreference = "Continue"
$outDir = Join-Path $PSScriptRoot "razer_bt_dump"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$log = @("Razer BLE Mouse Data Collection", "Generated: $timestamp", "")

function Log($msg) {
    $log += $msg
    Write-Host $msg
}

# --- 1. Copy Razer INF files ---
Log "=== Copying Razer INF files ==="
$infDir = "C:\Windows\INF"
$razerInfs = @()

# Find all Razer-related INFs by content
Get-ChildItem "$infDir\oem*.inf" | ForEach-Object {
    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match "(?i)razer|068e|RzDev|RzCommon|RZCONTROL") {
        $dest = Join-Path $outDir $_.Name
        Copy-Item $_.FullName $dest -Force
        $razerInfs += $_.Name
        Log "  Copied $($_.Name)"
        # Also grab the precompiled .PNF if it exists
        $pnf = $_.FullName -replace '\.inf$', '.PNF'
        if (Test-Path $pnf) {
            Copy-Item $pnf (Join-Path $outDir ($_.Name -replace '\.inf$', '.PNF')) -Force
        }
    }
}
if ($razerInfs.Count -eq 0) {
    # Fallback: copy the specific ones we know about
    foreach ($inf in @("oem56.inf", "oem66.inf")) {
        $src = Join-Path $infDir $inf
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $outDir $inf) -Force
            $razerInfs += $inf
            Log "  Copied $inf (fallback)"
        }
    }
}
Log "  Found $($razerInfs.Count) Razer INF files"
Log ""

# --- 2. Dump Razer driver files list ---
Log "=== Razer driver files ==="
$driverDump = @()
$driverPaths = @(
    "C:\Windows\System32\drivers\RzDev_00ba.sys",
    "C:\Windows\System32\drivers\RzCommon.sys",
    "C:\Windows\System32\drivers\RzDev*.sys",
    "C:\Windows\System32\drivers\Rz*.sys"
)
foreach ($pattern in $driverPaths) {
    Get-ChildItem $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        $info = [PSCustomObject]@{
            Name = $_.Name
            Size = $_.Length
            Modified = $_.LastWriteTime
            Version = (Get-ItemProperty $_.FullName).VersionInfo.FileVersion
        }
        $driverDump += "$($_.Name) | Size: $($_.Length) | Modified: $($_.LastWriteTime) | Version: $((Get-ItemProperty $_.FullName).VersionInfo.FileVersion)"
        Log "  $($_.Name) ($($_.Length) bytes)"
    }
}
$driverDump | Out-File (Join-Path $outDir "driver_files.txt") -Encoding UTF8
Log ""

# --- 3. Dump HID Report Descriptors ---
Log "=== HID Report Descriptors ==="
$hidDumpFile = Join-Path $outDir "hid_report_descriptors.txt"
$hidDump = @("HID Report Descriptors for Razer BLE Mouse", "=" * 60, "")

# Find all HID devices related to the Razer BLE mouse
$razerHidDevices = Get-PnpDevice | Where-Object {
    $_.InstanceId -match "00001812.*068E.*00BA" -or
    $_.InstanceId -match "RZCONTROL.*068E.*00BA"
}

foreach ($dev in $razerHidDevices) {
    $id = $dev.InstanceId
    $hidDump += "=" * 60
    $hidDump += "Device: $id"
    $hidDump += "Description: $($dev.FriendlyName)"
    $hidDump += ""

    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id"

    # Device Parameters
    $paramPath = "$regBase\Device Parameters"
    if (Test-Path $paramPath) {
        $hidDump += "--- Device Parameters ---"
        Get-ItemProperty $paramPath -ErrorAction SilentlyContinue | ForEach-Object {
            $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $val = $_.Value
                if ($val -is [byte[]]) {
                    $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                    $hidDump += "  $($_.Name) = [byte[$($val.Length)]] $hex"
                } else {
                    $hidDump += "  $($_.Name) = $val"
                }
            }
        }
        $hidDump += ""
    }

    # Recurse all subkeys
    if (Test-Path $regBase) {
        Get-ChildItem $regBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $subPath = $_.PSPath
            $relPath = $_.Name -replace [regex]::Escape("HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$id"), ""
            $hidDump += "--- Registry: $relPath ---"
            Get-ItemProperty $subPath -ErrorAction SilentlyContinue | ForEach-Object {
                $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $val = $_.Value
                    if ($val -is [byte[]]) {
                        $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                        $hidDump += "  $($_.Name) = [byte[$($val.Length)]] $hex"
                    } else {
                        $hidDump += "  $($_.Name) = $val"
                    }
                }
            }
            $hidDump += ""
        }
    }

    Log "  Dumped: $id"
}

$hidDump | Out-File $hidDumpFile -Encoding UTF8
Log ""

# --- 4. Dump the BLE HID parent device (BTHLEDEVICE 0x1812) ---
Log "=== BLE HID Parent Device ==="
$bleHidDumpFile = Join-Path $outDir "ble_hid_parent.txt"
$bleHidDump = @("BLE HID Service Parent Device", "=" * 60, "")

$bleHidParent = Get-PnpDevice | Where-Object {
    $_.InstanceId -match "BTHLEDEVICE.*00001812.*068E.*00BA"
}

foreach ($dev in $bleHidParent) {
    $id = $dev.InstanceId
    $bleHidDump += "InstanceId: $id"
    $bleHidDump += ""

    # All PnP properties
    $bleHidDump += "--- PnP Properties ---"
    Get-PnpDeviceProperty -InstanceId $id -ErrorAction SilentlyContinue | ForEach-Object {
        $val = $_.Data
        if ($val -is [byte[]]) {
            $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
            $bleHidDump += "  $($_.KeyName) = [byte[$($val.Length)]] $hex"
        } else {
            $bleHidDump += "  $($_.KeyName) = $val"
        }
    }
    $bleHidDump += ""

    # Full registry dump
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id"
    if (Test-Path $regBase) {
        $bleHidDump += "--- Registry (recursive) ---"
        Get-ChildItem $regBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $subPath = $_.PSPath
            $relPath = $_.Name -replace [regex]::Escape("HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$id"), ""
            $bleHidDump += "  [$relPath]"
            Get-ItemProperty $subPath -ErrorAction SilentlyContinue | ForEach-Object {
                $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $val = $_.Value
                    if ($val -is [byte[]]) {
                        $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                        $bleHidDump += "    $($_.Name) = [byte[$($val.Length)]] $hex"
                    } else {
                        $bleHidDump += "    $($_.Name) = $val"
                    }
                }
            }
        }
    }

    Log "  Dumped BLE HID parent: $id"
}

$bleHidDump | Out-File $bleHidDumpFile -Encoding UTF8
Log ""

# --- 5. Dump RZCONTROL device details ---
Log "=== RZCONTROL Device ==="
$rzDumpFile = Join-Path $outDir "rzcontrol_device.txt"
$rzDump = @("Razer Control Device (RZCONTROL)", "=" * 60, "")

$rzDevices = Get-PnpDevice | Where-Object { $_.InstanceId -match "RZCONTROL" }
foreach ($dev in $rzDevices) {
    $id = $dev.InstanceId
    $rzDump += "InstanceId: $id"

    # All properties
    Get-PnpDeviceProperty -InstanceId $id -ErrorAction SilentlyContinue | ForEach-Object {
        $val = $_.Data
        if ($val -is [byte[]]) {
            $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
            $rzDump += "  $($_.KeyName) = [byte[$($val.Length)]] $hex"
        } else {
            $rzDump += "  $($_.KeyName) = $val"
        }
    }
    $rzDump += ""

    # Registry
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id"
    if (Test-Path $regBase) {
        $rzDump += "--- Registry (recursive) ---"
        Get-ChildItem $regBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $subPath = $_.PSPath
            $relPath = $_.Name -replace [regex]::Escape("HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$id"), ""
            $rzDump += "  [$relPath]"
            Get-ItemProperty $subPath -ErrorAction SilentlyContinue | ForEach-Object {
                $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $val = $_.Value
                    if ($val -is [byte[]]) {
                        $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                        $rzDump += "    $($_.Name) = [byte[$($val.Length)]] $hex"
                    } else {
                        $rzDump += "    $($_.Name) = $val"
                    }
                }
            }
        }
    }

    Log "  Dumped RZCONTROL: $id"
}

$rzDump | Out-File $rzDumpFile -Encoding UTF8
Log ""

# --- 6. Dump Razer driver registry keys (service config) ---
Log "=== Razer Driver Service Registry ==="
$svcDumpFile = Join-Path $outDir "razer_driver_services.txt"
$svcDump = @("Razer Driver Service Configuration", "=" * 60, "")

foreach ($svcName in @("RzDev_00ba", "RzCommon", "RzDev")) {
    $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
    if (Test-Path $svcPath) {
        $svcDump += "=== Service: $svcName ==="
        Get-ItemProperty $svcPath -ErrorAction SilentlyContinue | ForEach-Object {
            $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $val = $_.Value
                if ($val -is [byte[]]) {
                    $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                    $svcDump += "  $($_.Name) = [byte[$($val.Length)]] $hex"
                } else {
                    $svcDump += "  $($_.Name) = $val"
                }
            }
        }

        # Recurse subkeys
        Get-ChildItem $svcPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $relPath = $_.Name -replace [regex]::Escape("HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$svcName"), ""
            $svcDump += "  [$relPath]"
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $val = $_.Value
                    if ($val -is [byte[]]) {
                        $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                        $svcDump += "    $($_.Name) = [byte[$($val.Length)]] $hex"
                    } else {
                        $svcDump += "    $($_.Name) = $val"
                    }
                }
            }
        }
        $svcDump += ""
        Log "  Dumped service: $svcName"
    }
}

$svcDump | Out-File $svcDumpFile -Encoding UTF8
Log ""

# --- 7. Dump HID Report Descriptor from the BLE HID service registry ---
Log "=== Raw HID Report Descriptor (from registry) ==="
$descDumpFile = Join-Path $outDir "hid_descriptor_raw.txt"
$descDump = @("Raw HID Report Descriptors", "=" * 60, "")

# The HID report descriptor is typically stored under the BTHLE HID device's registry
# Look in multiple locations where Windows stores it
$searchPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHLEDevice\{00001812-0000-1000-8000-00805f9b34fb}_Dev_VID&02068e_PID&00ba*",
    "HKLM:\SYSTEM\CurrentControlSet\Enum\HID\{00001812-0000-1000-8000-00805f9b34fb}_Dev_VID&02068e_PID&00ba*"
)

foreach ($searchPath in $searchPaths) {
    Get-ChildItem $searchPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $props.PSObject.Properties | Where-Object {
            $_.Name -match "(?i)descriptor|report|hid" -and $_.Value -is [byte[]]
        } | ForEach-Object {
            $hex = ($_.Value | ForEach-Object { "{0:X2}" -f $_ }) -join " "
            $descDump += "Path: $($props.PSPath)"
            $descDump += "Name: $($_.Name)"
            $descDump += "Size: $($_.Value.Length) bytes"
            $descDump += "Hex: $hex"
            $descDump += ""
            Log "  Found descriptor: $($_.Name) ($($_.Value.Length) bytes)"
        }
    }
}

# Also check the HID class key for report descriptors
$hidClassPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{4d1e55b2-f16f-11cf-88cb-001111000030}",
    "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{745a17a0-74d3-11d0-b6fe-00a0c90f57da}"
)
foreach ($classPath in $hidClassPaths) {
    if (Test-Path $classPath) {
        Get-ChildItem $classPath -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "068e" -or $_.Name -match "00ba"
        } | ForEach-Object {
            $descDump += "--- Device Class Entry ---"
            $descDump += "Path: $($_.Name)"
            Get-ChildItem $_.PSPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                        $val = $_.Value
                        if ($val -is [byte[]]) {
                            $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                            $descDump += "  $($_.Name) = [byte[$($val.Length)]] $hex"
                        } else {
                            $descDump += "  $($_.Name) = $val"
                        }
                    }
                }
            }
            $descDump += ""
        }
    }
}

$descDump | Out-File $descDumpFile -Encoding UTF8
Log ""

# --- 8. Use hidpython/ctypes to read HID report descriptor if possible ---
Log "=== HID Preparsed Data ==="
$preparsedFile = Join-Path $outDir "hid_preparsed.txt"
$preparsedDump = @("HID Preparsed Data / Caps", "=" * 60, "")

# Try to get HID capabilities via PowerShell .NET interop
# This reads the HID_CAPS structure which tells us about report types
$hidDevicePaths = Get-PnpDevice | Where-Object {
    $_.InstanceId -match "HID.*00001812.*068E.*00BA"
} | ForEach-Object {
    $id = $_.InstanceId
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters"
    $preparsedDump += "=== $id ==="

    if (Test-Path $regPath) {
        Get-ItemProperty $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $val = $_.Value
                if ($val -is [byte[]]) {
                    $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                    $preparsedDump += "  $($_.Name) = [byte[$($val.Length)]] $hex"
                } else {
                    $preparsedDump += "  $($_.Name) = $val"
                }
            }
        }
    }
    $preparsedDump += ""
    Log "  Caps for: $id"
}

$preparsedDump | Out-File $preparsedFile -Encoding UTF8
Log ""

# --- 9. Dump the Razer device class GUID registry ---
Log "=== Razer Device Class Registry ==="
$rzClassFile = Join-Path $outDir "razer_device_class.txt"
$rzClassDump = @("Razer Device Class {1750F915-5639-497C-966C-3A65ACECFCB6}", "=" * 60, "")

$rzClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{1750F915-5639-497C-966C-3A65ACECFCB6}"
if (Test-Path $rzClassPath) {
    Get-ChildItem $rzClassPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $relPath = $_.Name -replace [regex]::Escape("HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{1750F915-5639-497C-966C-3A65ACECFCB6}"), ""
        $rzClassDump += "[$relPath]"
        Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $val = $_.Value
                if ($val -is [byte[]]) {
                    $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                    $rzClassDump += "  $($_.Name) = [byte[$($val.Length)]] $hex"
                } else {
                    $rzClassDump += "  $($_.Name) = $val"
                }
            }
        }
        $rzClassDump += ""
    }
    Log "  Dumped Razer device class"
} else {
    $rzClassDump += "  (path not found)"
    Log "  Razer device class path not found"
}

$rzClassDump | Out-File $rzClassFile -Encoding UTF8
Log ""

# --- 10. Enumerate GATT characteristics via BluetoothGATT API ---
Log "=== BLE GATT Service Handles ==="
$gattFile = Join-Path $outDir "gatt_handles.txt"
$gattDump = @("GATT Service Attribute Handles", "=" * 60, "")

# Get all BTHLE service devices for this mouse
Get-PnpDevice | Where-Object {
    $_.InstanceId -match "BTHLEDEVICE.*068E.*00BA"
} | Sort-Object { [int]($_.InstanceId -replace '.*&(\d+)$', '$1') } | ForEach-Object {
    $id = $_.InstanceId
    # Extract service UUID from instance ID
    $svcMatch = [regex]::Match($id, '\{([0-9a-fA-F-]+)\}')
    $svcUuid = if ($svcMatch.Success) { $svcMatch.Groups[1].Value } else { "unknown" }

    $gattDump += "Service: $svcUuid"
    $gattDump += "  InstanceId: $id"

    Get-PnpDeviceProperty -InstanceId $id -ErrorAction SilentlyContinue | Where-Object {
        $_.KeyName -match "(?i)handle|service|gatt|bluetooth"
    } | ForEach-Object {
        $val = $_.Data
        if ($val -is [byte[]]) {
            $hex = ($val | ForEach-Object { "{0:X2}" -f $_ }) -join " "
            $gattDump += "  $($_.KeyName) = [byte[$($val.Length)]] $hex"
        } else {
            $gattDump += "  $($_.KeyName) = $val"
        }
    }
    $gattDump += ""
}

$gattDump | Out-File $gattFile -Encoding UTF8
Log ""

# --- 11. Check for Synapse/Razer user-mode components ---
Log "=== Razer User-Mode Components ==="
$userModeFile = Join-Path $outDir "razer_usermode.txt"
$userModeDump = @("Razer User-Mode Services and Processes", "=" * 60, "")

# Running processes
$userModeDump += "--- Running Processes ---"
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match "(?i)razer|synapse|rz"
} | ForEach-Object {
    $userModeDump += "  $($_.ProcessName) (PID: $($_.Id)) Path: $($_.Path)"
}
$userModeDump += ""

# Windows services
$userModeDump += "--- Windows Services ---"
Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match "(?i)razer|rz" -or $_.DisplayName -match "(?i)razer"
} | ForEach-Object {
    $userModeDump += "  $($_.Name) [$($_.Status)] - $($_.DisplayName)"
}
$userModeDump += ""

# COM objects / Named pipes that Synapse might use
$userModeDump += "--- Named Pipes (Razer) ---"
Get-ChildItem "\\.\pipe\" -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match "(?i)razer|rz|synapse"
} | ForEach-Object {
    $userModeDump += "  $($_.Name)"
}

$userModeDump | Out-File $userModeFile -Encoding UTF8
Log ""

# --- Summary ---
Log "=== Collection Complete ==="
Log "Output directory: $outDir"
Log ""
Log "Files collected:"
Get-ChildItem $outDir | ForEach-Object {
    Log "  $($_.Name) ($($_.Length) bytes)"
}

$log | Out-File (Join-Path $outDir "collection_log.txt") -Encoding UTF8

Write-Host ""
Write-Host "Done! Copy the entire '$outDir' directory back for analysis." -ForegroundColor Green
Write-Host "Most important files:" -ForegroundColor Yellow
Write-Host "  - oem66.inf (Razer mouse driver - DPI/config commands)" -ForegroundColor Yellow
Write-Host "  - oem56.inf (Razer common control driver)" -ForegroundColor Yellow
Write-Host "  - hid_report_descriptors.txt (HID collections with Output/Feature reports)" -ForegroundColor Yellow
Write-Host "  - hid_descriptor_raw.txt (raw HID report descriptor bytes)" -ForegroundColor Yellow
Write-Host "  - rzcontrol_device.txt (Razer Control Device properties)" -ForegroundColor Yellow
