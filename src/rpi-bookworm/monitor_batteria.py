#!/usr/bin/env python3
# monitor_batteria.py v1.8 (Bookworm, Raspberry Pi 3A+) - INA219 (0x40) su GPIO2/GPIO3, 3.3V
# - Nessuna libreria esterna: legge /dev/i2c-1 direttamente (serve solo Python 3).
# - Pacco 2S LiFePO4 (nominale 6.4 V, pieno ~7.2 V, vuoto ~5.0 V). Per un altro pacco
#   cambia SOGLIE_STATO qui sotto.
# - Corrente dalla tensione sullo shunt (SHUNT_OHM = 0.1 ohm, come i moduli INA219 standard):
#   non serve la calibrazione.
# Uso:  python3 monitor_batteria.py          (testo leggibile)
#       python3 monitor_batteria.py --csv    (una riga: data,V,mA,W,stato)
import datetime
import fcntl
import os
import struct
import sys

I2C_BUS = "/dev/i2c-1"
INA219_ADDR = 0x40
SHUNT_OHM = 0.1

# (tensione minima in V, stato): a riposo o carico leggero. La curva LiFePO4 e piatta:
# sono indicazioni di massima, non una misura di carica.
SOGLIE_STATO = [
    (7.0, "PIENA"),
    (6.6, "BUONA"),
    (6.3, "DISCRETA"),
    (5.8, "BASSA"),
]
STATO_MINIMO = "CRITICA!"

I2C_SLAVE = 0x0703
REG_SHUNT = 0x01
REG_BUS = 0x02


def leggi_registro(fd, reg):
    """Legge un registro a 16 bit (big endian) dell'INA219."""
    os.write(fd, bytes([reg]))
    dati = os.read(fd, 2)
    if len(dati) != 2:
        raise IOError("INA219: lettura incompleta")
    return struct.unpack(">H", dati)[0]


def converti(raw_bus, raw_shunt):
    """Da registri grezzi a (volt, mA, watt).
    Bus: bit 15..3 = tensione, 4 mV per passo. Shunt: signed 16 bit, 10 uV per passo."""
    volt = ((raw_bus >> 3) * 4) / 1000.0
    if raw_shunt >= 0x8000:
        raw_shunt -= 0x10000
    shunt_mv = raw_shunt * 0.01
    ma = shunt_mv / SHUNT_OHM
    watt = volt * ma / 1000.0
    return volt, ma, watt


def stato_batteria(volt):
    for soglia, nome in SOGLIE_STATO:
        if volt >= soglia:
            return nome
    return STATO_MINIMO


def main():
    csv = "--csv" in sys.argv
    fd = os.open(I2C_BUS, os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE, INA219_ADDR)
        volt, ma, watt = converti(leggi_registro(fd, REG_BUS), leggi_registro(fd, REG_SHUNT))
    finally:
        os.close(fd)
    stato = stato_batteria(volt)
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if csv:
        print(f"{ts},{volt:.3f},{ma:.0f},{watt:.2f},{stato}")
    else:
        print(f"[{ts}]")
        print(f"Tensione:  {volt:.3f} V")
        print(f"Corrente:  {ma:.1f} mA")
        print(f"Potenza:   {watt:.2f} W")
        print(f"Batteria:  {stato}")


if __name__ == "__main__":
    main()
