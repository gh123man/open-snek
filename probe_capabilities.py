#!/usr/bin/env python3
"""Automated capability probe for open-snek transports."""

import argparse
import json
from typing import Any, Dict



def find_mouse(transport: str, debug: bool = False):
    if transport == "usb":
        import razer_usb as transport_mod
        return transport_mod.find_razer_mouse(debug_hid=debug)
    else:
        import razer_ble as transport_mod
        return transport_mod.find_razer_mouse(debug_hid=debug, enable_vendor_gatt=False)


def run_probe(mouse, transport: str, include_vendor: bool = False) -> Dict[str, Any]:
    out: Dict[str, Any] = {"transport": transport, "results": {}}
    checks = {
        "serial": lambda: mouse.get_serial(),
        "firmware": lambda: mouse.get_firmware(),
        "device_mode": lambda: mouse.get_device_mode(),
        "dpi": lambda: mouse.get_dpi(),
        "dpi_stages": lambda: mouse.get_dpi_stages(),
        "poll_rate": lambda: mouse.get_poll_rate(),
        "idle_time": lambda: mouse.get_idle_time(),
        "low_battery_threshold": lambda: mouse.get_low_battery_threshold(),
        "scroll_mode": lambda: mouse.get_scroll_mode(),
        "scroll_acceleration": lambda: mouse.get_scroll_acceleration(),
        "scroll_smart_reel": lambda: mouse.get_scroll_smart_reel(),
        "scroll_led_brightness": lambda: mouse.get_scroll_led_brightness(),
    }

    if transport == "ble" and include_vendor:
        checks["ble_power_timeout_raw"] = lambda: mouse.get_power_timeout_raw()
        checks["ble_sleep_timeout_raw"] = lambda: mouse.get_sleep_timeout_raw()
        checks["ble_lighting_raw"] = lambda: mouse.get_lighting_value_raw()

    for name, fn in checks.items():
        try:
            out["results"][name] = {"ok": True, "value": fn()}
        except Exception as e:
            out["results"][name] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

    return out


def main() -> int:
    p = argparse.ArgumentParser(description="Probe open-snek feature support for current transport")
    p.add_argument("--transport", choices=["usb", "ble"], required=True)
    p.add_argument("--debug-hid", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--include-vendor", action="store_true", help="Include BLE vendor GATT checks")
    p.add_argument("--include-battery", action="store_true", help="Include battery checks (may hit CoreBluetooth paths)")
    args = p.parse_args()

    mouse = find_mouse(args.transport, debug=args.debug_hid)
    if mouse is None:
        print(f"No {args.transport.upper()} mouse interface found")
        return 1

    result = run_probe(mouse, args.transport, include_vendor=args.include_vendor)
    if args.include_battery:
        try:
            result["results"]["battery"] = {"ok": True, "value": mouse.get_battery()}
        except Exception as e:
            result["results"]["battery"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    if args.json:
        print(json.dumps(result, indent=2, default=str))
    else:
        print(f"Transport: {result['transport']}")
        for k, v in result["results"].items():
            if v.get("ok"):
                print(f"- {k}: {v.get('value')}")
            else:
                print(f"- {k}: ERROR {v.get('error')}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
