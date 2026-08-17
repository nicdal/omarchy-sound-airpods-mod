#!/usr/bin/env python3
"""Bridge between MagicPodsCore and the Omarchy shell AirPods plugin.

MagicPodsCore (magicpodscore.service) exposes a WebSocket on 127.0.0.1:2020
carrying AirPods battery levels and ANC state. This script speaks just enough
of that protocol for the bar widget.

  airpods.py watch            stream one compact JSON state object per line
  airpods.py set-anc <mode>   switch ANC mode (1 = off, 2 = transparency,
                              16 = noise cancellation)
  airpods.py demo [pro|max]   stream a synthetic device instead, for working on
                              the panel with no AirPods present. "pro" reports
                              left/right/case, "max" a single battery.
  airpods.py set-anc <mode> --demo   switch the synthetic device's mode
"""

import json
import os
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
PORT = 2020

# ANC bitmask values as reported by MagicPodsCore's `capabilities.anc`.
ANC_OFF = 1
ANC_TRANSPARENCY = 2
ANC_NOISE_CANCELLATION = 16

# status == 2 means "this component reported a real reading".
STATUS_PRESENT = 2

# How long to keep showing the last known device state while we're unable to
# talk to magicpodscore, and how long to wait between reconnect attempts.
# The grace window has to comfortably exceed the delay, or a single hang-up
# would still blank the widget before the next attempt lands.
RECONNECT_DELAY = 2
RECONNECT_GRACE = 20


def decode_frame(data):
    length = data[1] & 0x7F
    offset = 2
    if length == 126:
        length = struct.unpack(">H", data[2:4])[0]
        offset = 4
    elif length == 127:
        length = struct.unpack(">Q", data[2:10])[0]
        offset = 10
    return data[offset : offset + length].decode()


def send_frame(s, msg):
    b = msg.encode()
    frame = bytearray([0x81])
    mask_key = os.urandom(4)
    length = len(b)
    if length < 126:
        frame.append(0x80 | length)
    else:
        frame.append(0x80 | 126)
        frame.extend(struct.pack(">H", length))
    frame.extend(mask_key)
    frame.extend(bytearray(b[i] ^ mask_key[i % 4] for i in range(len(b))))
    s.send(bytes(frame))


def ws_connect(timeout=5):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    req = (
        "GET / HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.send(req.encode())
    s.recv(4096)  # HTTP upgrade + init frame
    return s


def ws_request(s, payload):
    send_frame(s, json.dumps(payload))
    return json.loads(decode_frame(s.recv(8192)))


DISCONNECTED = {"connected": False, "name": "", "address": "", "battery": [], "anc": None}


def build_state(data):
    """Reduce a MagicPodsCore GetAll payload to what the panel renders."""
    info = (data or {}).get("info")
    if not info or not info.get("connected"):
        return DISCONNECTED

    capabilities = info.get("capabilities", {}) or {}
    battery = capabilities.get("battery", {}) or {}

    components = []
    single = battery.get("single", {}) or {}
    if single.get("status") == STATUS_PRESENT:
        components.append(
            {"label": "Battery", "pct": single.get("battery", 0), "charging": bool(single.get("charging"))}
        )
    else:
        for label, key in (("Left", "left"), ("Right", "right"), ("Case", "case")):
            component = battery.get(key, {}) or {}
            if component.get("status") == STATUS_PRESENT:
                components.append(
                    {
                        "label": label,
                        "pct": component.get("battery", 0),
                        "charging": bool(component.get("charging")),
                    }
                )

    anc = capabilities.get("anc") or {}
    anc_state = None
    if anc.get("options"):
        anc_state = {"options": anc.get("options", 0), "selected": anc.get("selected", 0)}

    return {
        "connected": True,
        "name": info.get("name", "AirPods"),
        "address": info.get("address", ""),
        "battery": components,
        "anc": anc_state,
    }


def emit(state, last):
    """Print state only when it differs, so the shell isn't woken needlessly."""
    line = json.dumps(state, separators=(",", ":"), sort_keys=True)
    if line != last:
        print(line, flush=True)
    return line


def watch():
    last = None
    # MagicPodsCore hangs up on idle clients, so a dropped socket says nothing
    # about whether the headphones are still there. Reporting "disconnected" on
    # every drop made the widget flap in and out of the bar. Reconnect quietly
    # and only give up on the device once reconnecting has failed for this long.
    last_good = None
    while True:
        try:
            s = ws_connect()
            s.settimeout(30)
            data = ws_request(s, {"method": "GetAll"})
            last_good = time.monotonic()
            last = emit(build_state(data), last)

            while True:
                try:
                    frame = s.recv(8192)
                    if not frame:
                        break
                    msg = json.loads(decode_frame(frame))
                    if "info" in msg:
                        data["info"] = msg["info"]
                    elif "headphones" in msg:
                        # The device list changed; re-query for the full state.
                        data = ws_request(s, {"method": "GetAll"})
                    last = emit(build_state(data), last)
                except socket.timeout:
                    # Periodic re-query catches anything the broadcasts missed.
                    data = ws_request(s, {"method": "GetAll"})
                    last_good = time.monotonic()
                    last = emit(build_state(data), last)

            s.close()
        except Exception:
            # magicpodscore down, or it hung up on us. Either way the device's
            # own state is unknown rather than known-absent.
            pass

        # Hold the last known state through a brief outage. Only once we've been
        # unable to read the daemon for RECONNECT_GRACE do we admit we don't know
        # and blank the widget.
        if last_good is None or (time.monotonic() - last_good) > RECONNECT_GRACE:
            last = emit(DISCONNECTED, last)
        time.sleep(RECONNECT_DELAY)


def set_anc(mode):
    s = ws_connect()
    try:
        state = build_state(ws_request(s, {"method": "GetAll"}))
        if not state["connected"] or not state["address"]:
            return 1
        ws_request(
            s,
            {
                "method": "SetCapabilities",
                "arguments": {
                    "address": state["address"],
                    "capabilities": {"anc": {"selected": mode}},
                },
            },
        )
    finally:
        s.close()
    return 0


# --- Demo mode -------------------------------------------------------------
# A synthetic device so the panel can be built and tested with no AirPods in
# the room. The chosen mode is kept in a small state file, which is what makes
# clicking a listening-mode pill actually move the highlight: `set-anc --demo`
# writes it, and the `demo` stream polls it.

DEMO_STATE_FILE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "omarchy-airpods-demo.json"
)

ALL_ANC_MODES = ANC_OFF | ANC_TRANSPARENCY | ANC_NOISE_CANCELLATION

DEMO_DEVICES = {
    # Buds-style: separate left, right, and case readings.
    "pro": {
        "connected": True,
        "name": "AirPods Pro (demo)",
        "address": "00:00:00:00:00:00",
        "battery": [
            {"label": "Left", "pct": 82, "charging": False},
            {"label": "Right", "pct": 17, "charging": False},
            {"label": "Case", "pct": 64, "charging": True},
        ],
        "anc": {"options": ALL_ANC_MODES, "selected": ANC_NOISE_CANCELLATION},
    },
    # Over-ear: one battery for the whole set, which is the `single` reading.
    "max": {
        "connected": True,
        "name": "AirPods Max (demo)",
        "address": "00:00:00:00:00:00",
        "battery": [
            {"label": "Battery", "pct": 46, "charging": False},
        ],
        "anc": {"options": ALL_ANC_MODES, "selected": ANC_TRANSPARENCY},
    },
}


def demo_selected_mode(fallback):
    try:
        with open(DEMO_STATE_FILE) as f:
            return int(json.load(f).get("selected", fallback))
    except Exception:
        return fallback


def demo_set_mode(mode):
    with open(DEMO_STATE_FILE, "w") as f:
        json.dump({"selected": mode}, f)


def demo(variant="pro"):
    base = DEMO_DEVICES.get(variant, DEMO_DEVICES["pro"])
    fallback = base["anc"]["selected"]
    last = None
    while True:
        state = json.loads(json.dumps(base))
        state["anc"]["selected"] = demo_selected_mode(fallback)
        last = emit(state, last)
        time.sleep(0.5)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    command = sys.argv[1]
    if command == "watch":
        watch()
        return 0
    if command == "demo":
        demo(sys.argv[2] if len(sys.argv) > 2 else "pro")
        return 0
    if command == "set-anc":
        if len(sys.argv) < 3:
            print("Usage: airpods.py set-anc <mode> [--demo]", file=sys.stderr)
            return 2
        try:
            mode = int(sys.argv[2])
            if "--demo" in sys.argv[3:]:
                demo_set_mode(mode)
                return 0
            return set_anc(mode)
        except Exception as e:
            print(f"Failed to set ANC mode: {e}", file=sys.stderr)
            return 1

    print(f"Unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
