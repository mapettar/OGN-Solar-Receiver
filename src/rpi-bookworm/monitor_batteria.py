#!/usr/bin/env python3
# monitor_batteria.py v1.9 (Bookworm, Raspberry Pi 3A+) - INA219 (0x40, oppure 0x41) su GPIO2/GPIO3, 3.3V
# - Nessuna libreria esterna: legge /dev/i2c-1 direttamente (serve solo Python 3).
# - Due profili di pacco: 2s-lifepo4 (nominale 6.4 V, pieno ~7.2 V, vuoto ~5.0 V, default)
#   e 3s-liion (nominale 11.1 V, pieno 12.6 V). Si sceglie con --pacco o con la
#   variabile d'ambiente OGN_PACCO.
# - Corrente dalla tensione sullo shunt (SHUNT_OHM = 0.1 ohm, come i moduli INA219 standard):
#   non serve la calibrazione.
# - Secondo INA219 (indirizzo 0x41, ponticello A0) in serie sul positivo tra l'uscita del
#   caricabatterie (VIN+) e il pacco (VIN-): misura la CARICA. La corrente e' positiva quando
#   entra nel pacco. Il primo INA219 (0x40) sta tra pacco e Mini560 e misura il CONSUMO.
# Uso:  python3 monitor_batteria.py                      (testo leggibile, pacco 2S)
#       python3 monitor_batteria.py --pacco 3s-liion     (stazione con pacco 3S)
#       python3 monitor_batteria.py --csv                (una riga: data,V,mA,W,stato)
#       python3 monitor_batteria.py --addr 0x41 --carica          (carica, testo leggibile)
#       python3 monitor_batteria.py --addr 0x41 --carica --csv    (una riga: data,V,mA,W)
import datetime
import fcntl
import os
import struct
import sys

I2C_BUS = "/dev/i2c-1"
INA219_ADDR = 0x40
SHUNT_OHM = 0.1

# Per ogni profilo: (tensione minima in V, stato), a riposo o carico leggero.
# La curva LiFePO4 e piatta: sono indicazioni di massima, non una misura di carica.
PROFILI = {
    "2s-lifepo4": [(7.0, "PIENA"), (6.6, "BUONA"), (6.3, "DISCRETA"), (5.8, "BASSA")],
    "3s-liion":   [(12.0, "PIENA"), (11.1, "BUONA"), (10.5, "DISCRETA"), (9.6, "BASSA")],
}
PROFILO_DEFAULT = "2s-lifepo4"
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


def stato_batteria(volt, profilo=PROFILO_DEFAULT):
    for soglia, nome in PROFILI[profilo]:
        if volt >= soglia:
            return nome
    return STATO_MINIMO


def scegli_profilo(argv):
    """--pacco NOME oppure variabile OGN_PACCO; se il nome non esiste, esce con un errore."""
    nome = os.environ.get("OGN_PACCO", PROFILO_DEFAULT)
    if "--pacco" in argv:
        i = argv.index("--pacco")
        nome = argv[i + 1] if i + 1 < len(argv) else ""
    if nome not in PROFILI:
        sys.exit("Profilo pacco sconosciuto: '%s'. Validi: %s" % (nome, ", ".join(sorted(PROFILI))))
    return nome


def scegli_indirizzo(argv):
    """--addr 0x41 (o 65); senza l'opzione vale 0x40."""
    if "--addr" not in argv:
        return INA219_ADDR
    i = argv.index("--addr")
    try:
        addr = int(argv[i + 1], 0)
    except (IndexError, ValueError):
        sys.exit("--addr vuole un indirizzo, per esempio 0x41")
    if not 0x40 <= addr <= 0x4F:
        sys.exit("Indirizzo INA219 fuori dall'intervallo 0x40-0x4F: %s" % hex(addr))
    return addr


def main():
    csv = "--csv" in sys.argv
    carica = "--carica" in sys.argv
    profilo = scegli_profilo(sys.argv)
    addr = scegli_indirizzo(sys.argv)
    fd = os.open(I2C_BUS, os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE, addr)
        volt, ma, watt = converti(leggi_registro(fd, REG_BUS), leggi_registro(fd, REG_SHUNT))
    finally:
        os.close(fd)
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if carica:
        # corrente positiva = entra nel pacco; tensione = lato pacco (VIN-)
        if csv:
            print(f"{ts},{volt:.3f},{ma:.0f},{watt:.2f}")
        else:
            print(f"[{ts}]")
            print(f"Tensione:  {volt:.3f} V (lato pacco)")
            print(f"Carica:    {ma:+.1f} mA (positiva = entra nel pacco)")
            print(f"Potenza:   {watt:+.2f} W")
        return
    stato = stato_batteria(volt, profilo)
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
