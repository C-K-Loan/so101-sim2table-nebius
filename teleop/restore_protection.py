#!/usr/bin/env python3
"""Restore Feetech STS3215 self-protection that clear_faults.py disabled.
reg 19 (Unloading Condition) -> 44 = cut torque on temperature | current | overload (factory default)
reg 13 (Max Temperature Limit) -> 70 C (factory default)
Usage: restore_protection.py /dev/tty.usbmodemXXXX [/dev/tty.usbmodemYYYY ...]
"""
import sys, time
from scservo_sdk import PortHandler, PacketHandler
pk = PacketHandler(0)
for port in sys.argv[1:]:
    ph = PortHandler(port); ph.openPort(); ph.setBaudRate(1000000); ph.clearPort()
    for sid in range(1, 7):
        if pk.ping(ph, sid)[1] != 0:
            print(f"{port}: motor {sid} no reply"); continue
        before19 = pk.read1ByteTxRx(ph, sid, 19)[0]; before13 = pk.read1ByteTxRx(ph, sid, 13)[0]
        pk.write1ByteTxRx(ph, sid, 40, 0); time.sleep(0.01)   # torque off
        pk.write1ByteTxRx(ph, sid, 55, 0); time.sleep(0.02)   # unlock EEPROM
        pk.write1ByteTxRx(ph, sid, 19, 44); time.sleep(0.02)  # protection bitmask: temp|current|overload
        pk.write1ByteTxRx(ph, sid, 13, 70); time.sleep(0.02)  # max temp 70C
        pk.write1ByteTxRx(ph, sid, 55, 1); time.sleep(0.02)   # lock EEPROM
        after19 = pk.read1ByteTxRx(ph, sid, 19)[0]; after13 = pk.read1ByteTxRx(ph, sid, 13)[0]
        print(f"{port}: motor {sid}: reg19 {before19}->{after19}  tempLimit {before13}->{after13}")
    ph.closePort()
