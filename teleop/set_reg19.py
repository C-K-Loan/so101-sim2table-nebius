#!/usr/bin/env python3
import sys, time
from scservo_sdk import PortHandler, PacketHandler
val = int(sys.argv[1]); pk = PacketHandler(0)
for port in sys.argv[2:]:
    ph = PortHandler(port); ph.openPort(); ph.setBaudRate(1000000); ph.clearPort()
    for s in range(1, 7):
        pk.write1ByteTxRx(ph, s, 40, 0); pk.write1ByteTxRx(ph, s, 55, 0); time.sleep(0.02)
        pk.write1ByteTxRx(ph, s, 19, val); time.sleep(0.02); pk.write1ByteTxRx(ph, s, 55, 1); time.sleep(0.02)
    print(port[-6:], "reg19 now:", [pk.read1ByteTxRx(ph, s, 19)[0] for s in range(1, 7)])
    ph.closePort()
