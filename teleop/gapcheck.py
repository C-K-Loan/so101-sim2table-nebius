#!/usr/bin/env python3
"""Read-only: per-joint gap between where the follower IS and where the leader's pose maps it to."""
import json, pathlib, sys
from scservo_sdk import PortHandler, PacketHandler
L_PORT, F_PORT = sys.argv[1], sys.argv[2]
pk = PacketHandler(0)
C = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration"
lj = json.loads((C / "teleoperators/so_leader/orange_teleop.json").read_text())
fj = json.loads((C / "robots/so_follower/orange_robot.json").read_text())
LMIN, LMAX, FMIN, FMAX = [0]*6, [4095]*6, [0]*6, [4095]*6
for n, m in lj.items(): LMIN[m["id"]-1], LMAX[m["id"]-1] = m["range_min"], m["range_max"]
for n, m in fj.items(): FMIN[m["id"]-1], FMAX[m["id"]-1] = m["range_min"], m["range_max"]
names = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
ERR = {1: "voltage", 2: "sensor", 4: "TEMP", 8: "current", 16: "angle", 32: "OVERLOAD"}
def rd(port):
    ph = PortHandler(port); ph.openPort(); ph.setBaudRate(1000000); ph.clearPort()
    out = []
    for s in range(1, 7):
        _m, rc, err = pk.ping(ph, s); p = pk.read2ByteTxRx(ph, s, 56)[0] if rc == 0 else None
        t = pk.read1ByteTxRx(ph, s, 63)[0] if rc == 0 else None
        out.append((p, t, "/".join(n for b, n in ERR.items() if err & b)))
    ph.closePort(); return out
lead, fol = rd(L_PORT), rd(F_PORT)
worst = 0; bad = False
print(f"{'joint':14s} {'leader':>7s} {'follower':>9s} {'target':>7s} {'gap':>6s}  temp  flags")
for i in range(6):
    lp, ft = lead[i][0], fol[i][0]
    tgt = None
    if lp is not None:
        n = min(1.0, max(0.0, (lp - LMIN[i]) / max(1, LMAX[i] - LMIN[i]))); tgt = int(FMIN[i] + n * (FMAX[i] - FMIN[i]))
    gap = None if (ft is None or tgt is None) else ft - tgt
    if gap is not None: worst = max(worst, abs(gap))
    if fol[i][2] or (fol[i][1] or 0) > 65: bad = True
    print(f"{names[i]:14s} {str(lp):>7s} {str(ft):>9s} {str(tgt):>7s} {str(gap):>6s}  {fol[i][1]}C  {fol[i][2] or 'ok'}")
print()
if bad: print("RESULT: NOT READY - follower has a fault flag or is hot. Power-cycle the follower 12V, let it cool.")
elif worst > 150: print(f"RESULT: NOT READY - worst gap {worst} counts. Pose the LEADER to match the follower (or recalibrate both in the same pose) until every gap < 150.")
else: print(f"RESULT: READY - worst gap {worst} counts. Run: bash ~/so101_run.sh record 10")
