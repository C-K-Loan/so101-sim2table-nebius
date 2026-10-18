#!/usr/bin/env python3
"""Gently ramp the follower onto the leader's current pose (via calibration mapping) before lerobot starts,
so the first lerobot step is tiny and no inrush trips the servos. Usage: prelaunch_align.py LEADER_PORT FOLLOWER_PORT"""
import json, pathlib, sys, time
from scservo_sdk import PortHandler, PacketHandler, GroupSyncWrite

L_PORT, F_PORT = sys.argv[1], sys.argv[2]
pk = PacketHandler(0)
C = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration"
lj = json.loads((C / "teleoperators/so_leader/orange_teleop.json").read_text())
fj = json.loads((C / "robots/so_follower/orange_robot.json").read_text())
LMIN, LMAX, FMIN, FMAX = [0]*6, [4095]*6, [0]*6, [4095]*6
for n, m in lj.items(): LMIN[m["id"]-1], LMAX[m["id"]-1] = m["range_min"], m["range_max"]
for n, m in fj.items(): FMIN[m["id"]-1], FMAX[m["id"]-1] = m["range_min"], m["range_max"]

L = PortHandler(L_PORT); L.openPort(); L.setBaudRate(1000000); L.clearPort()
F = PortHandler(F_PORT); F.openPort(); F.setBaudRate(1000000); F.clearPort()
def pos(ph, s):
    p, r, _ = pk.read2ByteTxRx(ph, s, 56); return p if r == 0 else None
lead = [pos(L, s) for s in range(1, 7)]
fol = [pos(F, s) for s in range(1, 7)]
target = []
for i in range(6):
    if lead[i] is None or fol[i] is None: target.append(fol[i]); continue
    n = min(1.0, max(0.0, (lead[i] - LMIN[i]) / max(1, LMAX[i] - LMIN[i])))
    target.append(int(round(FMIN[i] + n * (FMAX[i] - FMIN[i]))))
print("follower now:", fol); print("target      :", target)
# gentle settings (RAM): torque limit 400/1000, accel 20
for s in range(1, 7):
    pk.write2ByteTxRx(F, s, 48, 400); pk.write1ByteTxRx(F, s, 41, 20); pk.write1ByteTxRx(F, s, 40, 1)
steps = 60
for k in range(1, steps + 1):
    g = GroupSyncWrite(F, pk, 42, 2)
    for i in range(6):
        if fol[i] is None or target[i] is None: continue
        v = int(fol[i] + (target[i] - fol[i]) * k / steps)
        g.addParam(i + 1, [v & 0xFF, (v >> 8) & 0xFF])
    g.txPacket(); time.sleep(0.05)
time.sleep(0.5)
after = [pos(F, s) for s in range(1, 7)]
print("follower after:", after, "| gap:", [None if (a is None or t is None) else a - t for a, t in zip(after, target)])
volt = pk.read1ByteTxRx(F, 2, 62)[0] / 10
# restore torque limit for lerobot (it expects full), keep accel gentle; torque stays ON so it holds pose
for s in range(1, 7):
    pk.write2ByteTxRx(F, s, 48, 1000)
print("rail:", volt, "V | aligned, torque ON (lerobot will take over)")
L.closePort(); F.closePort()
