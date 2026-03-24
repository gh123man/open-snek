from typing import Optional, Tuple

try:
    from ble_battery import HAS_COREBLUETOOTH, read_razer_battery_ble
except ImportError:
    HAS_COREBLUETOOTH = False

    def read_razer_battery_ble(**kwargs):
        return None


USB_VENDOR_ID_RAZER = 0x1532
BT_VENDOR_ID_RAZER = 0x068E
RAZER_USB_REPORT_LEN = 90
RAZER_STATUS_BUSY = 0x01

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

KNOWN_MICE = {
    0x00B9: ("Razer Basilisk V3 X HyperSpeed", 18000),
    0x00CB: ("Razer Basilisk V3 35K", 35000),
    0x0083: ("Razer Basilisk V3", 26000),
    0x0084: ("Razer Basilisk V3", 26000),
    0x00BA: ("Razer Basilisk V3 X HyperSpeed (BT)", 18000),
}

TRANSACTION_ID_CANDIDATES = {
    0x00BA: [0x3F, 0x1F, 0xFF],
}


def parse_rgb_hex(value: str) -> Optional[Tuple[int, int, int]]:
    s = (value or "").strip().lower().replace("#", "")
    if len(s) != 6:
        return None
    try:
        return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))
    except Exception:
        return None


def print_status(mouse, extra_status=None):
    print("\n" + "=" * 50)
    print("  Current Settings")
    print("=" * 50)

    serial = mouse.get_serial()
    if serial:
        print(f"\n  Serial:         {serial}")

    fw = mouse.get_firmware()
    if fw:
        print(f"\n  Firmware:       v{fw[0]}.{fw[1]}")

    dpi = mouse.get_dpi()
    if dpi:
        print(f"\n  Current DPI:    {dpi[0]}" + (f" x {dpi[1]}" if dpi[0] != dpi[1] else ""))

    stages = mouse.get_dpi_stages()
    if stages:
        active, stage_list = stages
        print(f"\n  DPI Stages:     {len(stage_list)} configured")
        for i, dpi_value in enumerate(stage_list):
            marker = "  <-- active" if i == active else ""
            print(f"    Stage {i + 1}:      {dpi_value}{marker}")

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

    battery = mouse.get_battery()
    if battery:
        level, charging = battery
        status = " (charging)" if charging else ""
        print(f"\n  Battery:        {level}%{status}")

    if extra_status is not None:
        extra_status(mouse)

    print()
