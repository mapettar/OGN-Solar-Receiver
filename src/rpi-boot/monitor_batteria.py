#!/usr/bin/env python3
# monitor_batteria.py v1.7 - INA219 (0x40) su GPIO2/GPIO3 della RPi, alimentato a 3.3V
# Pacco Li-ion 3S2P (12.6V pieno). Librerie in /boot/python-libs.
import sys
sys.path.insert(0, '/boot/python-libs')

import board
import busio
from adafruit_ina219 import INA219
import datetime

i2c = busio.I2C(board.SCL, board.SDA)
ina = INA219(i2c)
ina.set_calibration_32V_2A()

tensione = ina.bus_voltage            # V (lato batteria, VIN+)
corrente = ina.current                # mA
potenza = tensione * (corrente / 1000.0)   # W calcolati a mano
timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

print(f"[{timestamp}]")
print(f"Tensione:  {tensione:.3f} V")
print(f"Corrente:  {corrente:.1f} mA")
print(f"Potenza:   {potenza:.2f} W")

# Stato batteria Li-ion 3S (soglie a riposo/carico leggero)
if tensione >= 12.0:
    stato = "PIENA"
elif tensione >= 11.1:
    stato = "BUONA"
elif tensione >= 10.5:
    stato = "DISCRETA"
elif tensione >= 9.6:
    stato = "BASSA"
else:
    stato = "CRITICA!"
print(f"Batteria:  {stato}")
