# BLE Vendor Key Sweeps (2026-03-08)

Device/context:
- Basilisk V3 X HyperSpeed BT (`VID 0x068e`, `PID 0x00ba`)
- macOS, vendor GATT enabled (default in current `razer_ble.py`)

Tools used:
- `discover_bt_vendor_keys.py`
- targeted read/write checks via `razer_ble.RazerMouse` internals

## Important Operational Note

- Do **not** run multiple BT vendor scans in parallel.
- Parallel CoreBluetooth probe processes caused response cross-talk and temporary bogus values.
- All validated results below were re-run single-process.

## Confirmed Mappings (High Confidence)

- Serial read fallback:
  - get: `01 83 00 00`
  - payload: ASCII serial (e.g. `632602H30204897`)

- Device mode (read fallback only in app logic):
  - get: `01 82 00 00` (`u16 LE`)
  - candidate set: `01 02 00 00` (`u16 LE`, op `0x02`)
  - observed values: `0x0000` normal, `0x0003` driver-like
  - safety: write path intentionally disabled in `razer_ble.py` due unstable/blinking-state risk on current firmware

- Idle-time aligned scalar:
  - get: `05 84 00 00` (`u16 LE`)
  - set: `05 04 00 00` (`u16 LE`, op `0x02`)
  - observed value: `240`

- Low-battery-threshold aligned scalar:
  - get: `05 82 00 00` (`u8`)
  - set: `05 02 00 00` (`u8`, op `0x01`)
  - observed value: `13`

- Battery raw/status:
  - `05 81 00 01` (`u8`) -> `242` (~94%)
  - `05 80 00 01` (`u8`) -> `1` (semantics still unknown)

- Lighting scalar:
  - get: `10 85 01 01` (`u8`)
  - set: `10 05 01 01` same-value writeback validated
  - observed value: `120`

## Candidate Keys (Not Yet Semantically Mapped)

`00xx` family (all tails `x000/x001/...` variants returned same payload classes):
- `00 80`:
  - tail low-byte even: payload `40 41 43`
  - tail low-byte odd: payload `00 01 05 06 08`
- `00 81`:
  - even tails: payload `01 00 05 00`
  - odd tails: empty payload with success status
- `00 83`: payload `14`

`01xx` family:
- `01 84`: `u8 = 1` (same-value writeback succeeds)
- `01 8A`: `u8 = 0` (same-value writeback succeeds)
- `01 8C`: `u8 = 1` (same-value writeback succeeds)
- `01 86`: payload `00 00 00`

`10xx` family:
- `10 82`: payload `00 01 02 03 05 08`
- `10 83`: payload `00` x 10
- `10 86`: payload `01 20 00 00 00`
- `10 80`: payload `40 41 42 C3 84 C5` / `01` depending tail

`0Bxx` family:
- Reconfirms DPI-stage table keyspace (`0B 84`, `0B 82`, `0B 81`, `0B 83`) with expected staged payload blobs.

## Safety Findings

- Attempting unknown write candidate on `00 03 00 00` did **not** ACK success and produced inconsistent readback on that unknown key.
- Unknown-key writes should remain disabled by default in tooling; prefer read-only scans plus explicit allowlists.

## Recommended Next Sweep Targets

- Focus read-only correlation on:
  - `00 80/81/83`
  - `10 82/86`
  - `01 84/8A/8C`
- Capture-driven approach:
  - perform one Synapse action at a time (poll-rate, firmware page, mode toggles)
  - compare key deltas against this candidate set.
