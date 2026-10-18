#!/usr/bin/env bash
# One-shot: restore servo protection on every connected SO-101 arm, show health, set ports.
#   bash ~/fix_arms.sh
export PATH="$HOME/lerobot-venv/bin:$PATH"
PY=~/lerobot-venv/bin/python
PORTS=$(ls /dev/tty.usbmodem* 2>/dev/null)
if [ -z "$PORTS" ]; then echo "No arms on USB. Plug them in and re-run."; exit 1; fi
echo "Arms found:"; echo "$PORTS"
echo
echo "=== 1. restore protection (reg19 -> 44, max temp -> 70) ==="
$PY ~/Desktop/hackathon_demo/restore_protection.py $PORTS
echo
echo "=== 2. health ==="
$PY - $PORTS <<'PYEOF'
import sys
from scservo_sdk import PortHandler, PacketHandler
pk = PacketHandler(0)
ERR = {1:"voltage",2:"sensor",4:"TEMP",8:"current",16:"angle",32:"OVERLOAD"}
for port in sys.argv[1:]:
    ph = PortHandler(port); ph.openPort(); ph.setBaudRate(1000000); ph.clearPort()
    print("==", port)
    for s in range(1, 7):
        m, rc, err = pk.ping(ph, s)
        if rc != 0: print(f"  motor {s}: NO REPLY"); continue
        t = pk.read1ByteTxRx(ph, s, 63)[0]; v = pk.read1ByteTxRx(ph, s, 62)[0]
        pk.write1ByteTxRx(ph, s, 40, 0)
        flags = [n for b, n in ERR.items() if err & b]
        print(f"  motor {s}: {t}C {v/10:.1f}V err={flags or 'ok'}")
    ph.closePort()
PYEOF
echo
L=/dev/tty.usbmodem5C821100701; F=/dev/tty.usbmodem5C821087081
if echo "$PORTS" | grep -q "$L" && echo "$PORTS" | grep -q "$F"; then
  sed -i.bak "s|export TELEOP_PORT=.*|export TELEOP_PORT=$L|; s|export ROBOT_PORT=.*|export ROBOT_PORT=$F|" ~/.so101_env
  echo "=== 3. ports set: LEADER=$L  FOLLOWER=$F (first pair) ==="
  echo "Next:  bash ~/so101_run.sh record 10"
else
  echo "=== 3. unknown pair. Set ports then calibrate: ==="
  echo "bash ~/so101_run.sh calibrate <LEADER_PORT> <FOLLOWER_PORT>   # then type c at both prompts"
fi
echo
echo "RULES: keep episodes short, let the follower rest limp (Esc) between episodes, stop if any motor > 65C."
