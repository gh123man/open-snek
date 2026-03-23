import argparse

from razer_common import parse_rgb_hex


def build_common_parser(*, note: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Configure Razer mouse settings on macOS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  %(prog)s                              Show current settings
  %(prog)s --dpi 1600                   Set DPI to 1600
  %(prog)s --stages 400,800,1600,3200   Set 4 DPI stages
  %(prog)s --stages 800,1600,3200 --active-stage 2
                                        Set stages with stage 2 active
  %(prog)s --single-dpi 1600            Use one fixed DPI stage
  %(prog)s --poll-rate 1000             Set polling rate to 1000 Hz

Note: {note}
        """,
    )
    parser.add_argument("--dpi", type=int, metavar="DPI", help="Set current DPI (100-30000)")
    parser.add_argument("--stages", type=str, metavar="DPI,DPI,...", help="Set DPI stages (comma-separated, 1-5 values)")
    parser.add_argument("--active-stage", type=int, metavar="N", help="Set active DPI stage (1-5)")
    parser.add_argument("--single-dpi", type=int, metavar="DPI", help="Set single fixed DPI mode (1 stage)")
    parser.add_argument("--poll-rate", type=int, choices=[125, 500, 1000], metavar="HZ", help="Set polling rate (125/500/1000 Hz)")
    parser.add_argument("--device-mode", choices=["normal", "driver"], help="Set device mode")
    parser.add_argument("--idle-time", type=int, metavar="SECONDS", help="Set idle timeout seconds (60-900)")
    parser.add_argument("--low-battery-threshold", type=int, metavar="RAW", help="Set low battery threshold raw value (0x0c-0x3f)")
    parser.add_argument("--scroll-mode", choices=["tactile", "freespin"], help="Set scroll wheel mode")
    parser.add_argument("--scroll-acceleration", choices=["on", "off"], help="Set scroll acceleration")
    parser.add_argument("--scroll-smart-reel", choices=["on", "off"], help="Set scroll smart reel")
    parser.add_argument("--scroll-led-brightness", type=int, metavar="0-255", help="Set scroll wheel LED brightness")
    parser.add_argument(
        "--scroll-led-effect",
        choices=["none", "spectrum", "wave-left", "wave-right", "breath-random"],
        help="Set scroll wheel LED effect",
    )
    parser.add_argument("--scroll-led-static", type=str, metavar="RRGGBB", help="Set static scroll LED color (hex)")
    parser.add_argument("--scroll-led-reactive", type=str, metavar="SPEED:RRGGBB", help="Set reactive scroll LED (speed 1-4)")
    parser.add_argument("--scroll-led-breath-single", type=str, metavar="RRGGBB", help="Set breathing single-color scroll LED")
    parser.add_argument("--scroll-led-breath-dual", type=str, metavar="RRGGBB:RRGGBB", help="Set breathing dual-color scroll LED")
    parser.add_argument("--usb-button-action", type=str, metavar="PROFILE:BTN:TYPE:PARAMHEX[:FN]", help="Experimental USB button action write (class 0x02 id 0x0D)")
    parser.add_argument("--quiet", "-q", action="store_true", help="Minimal output")
    parser.add_argument("--debug-hid", action="store_true", help="Enable verbose HID transport debug output")
    return parser


def dispatch_common_commands(mouse, args):
    made_changes = False

    if args.single_dpi:
        val = max(100, min(30000, int(args.single_dpi)))
        print(f"\nSetting single fixed DPI mode: {val}")
        if mouse.set_dpi_stages([val], 0):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    elif args.stages:
        try:
            stages = [int(x.strip()) for x in args.stages.split(",")]
            if len(stages) < 1 or len(stages) > 5:
                print("Error: Specify 1-5 DPI stages")
                return 1, made_changes

            active = (args.active_stage - 1) if args.active_stage else 0
            active = max(0, min(len(stages) - 1, active))

            print(f"\nSetting DPI stages: {stages}")
            print(f"Active stage: {active + 1}")

            if mouse.set_dpi_stages(stages, active):
                print("  Success!")
                made_changes = True
            else:
                print("  Failed!")
                return 1, made_changes
        except ValueError:
            print("Error: Invalid DPI values. Use comma-separated numbers.")
            return 1, made_changes

    elif args.active_stage:
        print(f"\nSetting active stage to: {args.active_stage}")
        if mouse.set_active_stage(args.active_stage):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed! (Stage out of range?)")
            return 1, made_changes

    if args.dpi:
        print(f"\nSetting DPI to: {args.dpi}")
        if mouse.set_dpi(args.dpi):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.poll_rate:
        print(f"\nSetting poll rate to: {args.poll_rate} Hz")
        if mouse.set_poll_rate(args.poll_rate):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.device_mode:
        mode = 0x03 if args.device_mode == "driver" else 0x00
        print(f"\nSetting device mode to: {args.device_mode}")
        if mouse.set_device_mode(mode, 0x00):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.idle_time is not None:
        print(f"\nSetting idle time to: {args.idle_time}s")
        if mouse.set_idle_time(args.idle_time):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.low_battery_threshold is not None:
        print(f"\nSetting low battery threshold raw to: {args.low_battery_threshold}")
        if mouse.set_low_battery_threshold(args.low_battery_threshold):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.scroll_mode:
        mode = 1 if args.scroll_mode == "freespin" else 0
        print(f"\nSetting scroll mode to: {args.scroll_mode}")
        if mouse.get_scroll_mode() is None:
            print("  Unsupported on this device/transport; skipping.")
            mode = None
        if mode is not None:
            if mouse.set_scroll_mode(mode):
                print("  Success!")
                made_changes = True
            else:
                print("  Failed!")
                return 1, made_changes

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
            return 1, made_changes

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
            return 1, made_changes

    if args.scroll_led_brightness is not None:
        print(f"\nSetting scroll LED brightness to: {args.scroll_led_brightness}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_brightness(args.scroll_led_brightness):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

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
                return 1, made_changes

    if args.scroll_led_static:
        rgb = parse_rgb_hex(args.scroll_led_static)
        if rgb is None:
            print("\nInvalid --scroll-led-static; expected RRGGBB.")
            return 1, made_changes
        print(f"\nSetting scroll LED static color to: #{args.scroll_led_static.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_static(*rgb):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.scroll_led_reactive:
        try:
            speed_s, rgb_s = args.scroll_led_reactive.split(":", 1)
            speed = int(speed_s, 0)
            rgb = parse_rgb_hex(rgb_s)
            if rgb is None:
                raise ValueError("bad rgb")
        except Exception:
            print("\nInvalid --scroll-led-reactive; expected SPEED:RRGGBB.")
            return 1, made_changes
        print(f"\nSetting scroll LED reactive effect speed={speed} color=#{rgb_s.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_reactive(speed, *rgb):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.scroll_led_breath_single:
        rgb = parse_rgb_hex(args.scroll_led_breath_single)
        if rgb is None:
            print("\nInvalid --scroll-led-breath-single; expected RRGGBB.")
            return 1, made_changes
        print(f"\nSetting scroll LED breathing single color to: #{args.scroll_led_breath_single.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_breath_single(*rgb):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.scroll_led_breath_dual:
        try:
            c1, c2 = args.scroll_led_breath_dual.split(":", 1)
            rgb1 = parse_rgb_hex(c1)
            rgb2 = parse_rgb_hex(c2)
            if rgb1 is None or rgb2 is None:
                raise ValueError("bad rgb")
        except Exception:
            print("\nInvalid --scroll-led-breath-dual; expected RRGGBB:RRGGBB.")
            return 1, made_changes
        print(f"\nSetting scroll LED breathing dual colors to: #{c1.strip().lstrip('#')} and #{c2.strip().lstrip('#')}")
        if mouse.get_scroll_led_brightness() is None:
            print("  Unsupported on this device/transport; skipping.")
        elif mouse.set_scroll_led_effect_breath_dual(*rgb1, *rgb2):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    if args.usb_button_action:
        try:
            parts = args.usb_button_action.split(":")
            if len(parts) not in (4, 5):
                raise ValueError("bad part count")
            profile = int(parts[0], 0)
            button_id = int(parts[1], 0)
            action_type = int(parts[2], 0)
            param_bytes = bytes.fromhex(parts[3].strip()) if parts[3].strip() else b""
            fn_flag = bool(int(parts[4], 0)) if len(parts) == 5 else False
        except Exception:
            print("\nInvalid --usb-button-action format. Use PROFILE:BTN:TYPE:PARAMHEX[:FN].")
            return 1, made_changes
        print(
            f"\nSetting USB button action profile={profile} button={button_id} "
            f"type=0x{action_type:02x} params={param_bytes.hex()} fn={int(fn_flag)}"
        )
        if mouse.set_usb_button_action(profile, button_id, action_type, param_bytes, fn_hypershift=fn_flag):
            print("  Success!")
            made_changes = True
        else:
            print("  Failed!")
            return 1, made_changes

    return 0, made_changes
