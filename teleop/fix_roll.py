#!/usr/bin/env python3
"""Zero both wrist_roll homing offsets in the calibration JSONs, re-zero both roll motors
at their current orientation (clears multi-turn overflow), clear fault flags, print health."""
import json, pathlib, time
from scservo_sdk import PortHandler, PacketHandler

pk = PacketHandler(0)
C = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration"
for f in [C / "teleoperators/so_leader/orange_teleop.json", C / "robots/so_follower/orange_robot.json"]:
    d = json.loads(f.read_text())
    d["wrist_roll"]["homing_offset"] = 0
    d["wrist_roll"]["range_min"] = 0
    d["wrist_roll"]["range_max"] = 4095
    f.write_text(json.dumps(d, indent=4))
    print(f.name, "-> wrist_roll homing_offset=0, range 0-4095")

ERR = {1: "voltage", 2: "sensor", 4: "TEMP", 8: "current", 16: "angle", 32: "OVERLOAD"}
for name, port in [("leader", "/dev/tty.usbmodem5C821100701"), ("follower", "/dev/tty.usbmodem5C821087081")]:
    ph = PortHandler(port); ph.openPort(); ph.setBaudRate(1000000); ph.clearPort()
    for s in range(1, 7):
        pk.write1ByteTxRx(ph, s, 40, 0)
    time.sleep(0.2)
    pk.write1ByteTxRx(ph, 5, 55, 0); time.sleep(0.05)
    pk.write1ByteTxRx(ph, 5, 31, 0); time.sleep(0.05)      # homing offset 0
    pk.write1ByteTxRx(ph, 5, 40, 128); time.sleep(0.3)     # set current position as 2048, clear multi-turn
    pk.write1ByteTxRx(ph, 5, 55, 1); time.sleep(0.05)
    pk.write1ByteTxRx(ph, 5, 40, 0); time.sleep(0.3)
    cells = []
    for s in range(1, 7):
        _m, _rc, err = pk.ping(ph, s)
        p = pk.read2ByteTxRx(ph, s, 56)[0]
        flags = "/".join(n for b, n in ERR.items() if err & b)
        cells.append(f"{s}:{p}" + (f"!{flags}" if flags else ""))
    print(name, "pos/err:", " ".join(cells))
    ph.closePort()
