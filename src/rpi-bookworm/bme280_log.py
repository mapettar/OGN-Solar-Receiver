#!/usr/bin/env python3
# bme280_log.py v1.0
# Legge un BME280 (I2C, 0x76 o 0x77) senza librerie esterne, scrive una riga
# di log e, se l'umidita' supera la soglia, un avviso in ogn-eventi.log.
#
# Uso:   python3 bme280_log.py            -> una lettura, scrive sul log
#        python3 bme280_log.py --test     -> stampa soltanto, non scrive nulla
#
# Collegare il sensore al lato 3,3 V della Pi (GPIO2 = SDA, GPIO3 = SCL).
import fcntl
import math
import os
import sys
import time

BUS = 1
INDIRIZZI = (0x76, 0x77)
I2C_SLAVE = 0x0703

LOG = "/boot/bme280.log"
EVENTI = "/boot/ogn-eventi.log"
STATO = "/run/bme280_alert"      # ricorda se l'allarme e' gia' stato scritto
RIGHE_MAX = 2000                 # righe massime tenute nel log
SOGLIA_UMIDITA = 80.0            # % RH oltre cui scrivere l'avviso
ISTERESI = 5.0                   # l'avviso si riarma sotto SOGLIA - ISTERESI


class Bme280:
    def __init__(self, bus=BUS):
        self.fd = os.open("/dev/i2c-%d" % bus, os.O_RDWR)
        self.addr = None
        for a in INDIRIZZI:
            try:
                fcntl.ioctl(self.fd, I2C_SLAVE, a)
                if self._leggi(0xD0, 1)[0] in (0x60, 0x58):
                    self.addr = a
                    break
            except OSError:
                continue
        if self.addr is None:
            raise OSError("BME280 non trovato su 0x76/0x77")
        self.chip = self._leggi(0xD0, 1)[0]
        self._calibrazione()

    def _leggi(self, reg, n):
        os.write(self.fd, bytes([reg]))
        return os.read(self.fd, n)

    def _scrivi(self, reg, val):
        os.write(self.fd, bytes([reg, val]))

    def _calibrazione(self):
        c = self._leggi(0x88, 26)
        u16 = lambda i: c[i] | (c[i + 1] << 8)
        s16 = lambda i: u16(i) - 65536 if u16(i) > 32767 else u16(i)
        self.T1, self.T2, self.T3 = u16(0), s16(2), s16(4)
        self.P1 = u16(6)
        self.P2, self.P3, self.P4, self.P5 = s16(8), s16(10), s16(12), s16(14)
        self.P6, self.P7, self.P8, self.P9 = s16(16), s16(18), s16(20), s16(22)
        self.H1 = c[25]
        if self.chip == 0x60:
            h = self._leggi(0xE1, 7)
            self.H2 = h[0] | (h[1] << 8)
            if self.H2 > 32767:
                self.H2 -= 65536
            self.H3 = h[2]
            self.H4 = (h[3] << 4) | (h[4] & 0x0F)
            if self.H4 > 2047:
                self.H4 -= 4096
            self.H5 = (h[5] << 4) | (h[4] >> 4)
            if self.H5 > 2047:
                self.H5 -= 4096
            self.H6 = h[6] - 256 if h[6] > 127 else h[6]

    def misura(self):
        """Ritorna (temperatura C, umidita' % o None, pressione hPa)."""
        if self.chip == 0x60:
            self._scrivi(0xF2, 0x01)          # oversampling umidita' x1
        self._scrivi(0xF4, 0x25)              # T x1, P x1, modo forzato
        time.sleep(0.05)
        d = self._leggi(0xF7, 8)
        adc_p = (d[0] << 12) | (d[1] << 4) | (d[2] >> 4)
        adc_t = (d[3] << 12) | (d[4] << 4) | (d[5] >> 4)
        adc_h = (d[6] << 8) | d[7]
        t, t_fine = self.compensa_t(adc_t)
        p = self.compensa_p(adc_p, t_fine) / 100.0
        h = self.compensa_h(adc_h, t_fine) if self.chip == 0x60 else None
        return t, h, p

    def compensa_t(self, adc_t):
        v1 = (adc_t / 16384.0 - self.T1 / 1024.0) * self.T2
        v2 = ((adc_t / 131072.0 - self.T1 / 8192.0) ** 2) * self.T3
        t_fine = v1 + v2
        return t_fine / 5120.0, t_fine

    def compensa_p(self, adc_p, t_fine):
        v1 = t_fine / 2.0 - 64000.0
        v2 = v1 * v1 * self.P6 / 32768.0
        v2 = v2 + v1 * self.P5 * 2.0
        v2 = v2 / 4.0 + self.P4 * 65536.0
        v1 = (self.P3 * v1 * v1 / 524288.0 + self.P2 * v1) / 524288.0
        v1 = (1.0 + v1 / 32768.0) * self.P1
        if v1 == 0:
            return 0.0
        p = 1048576.0 - adc_p
        p = (p - v2 / 4096.0) * 6250.0 / v1
        v1 = self.P9 * p * p / 2147483648.0
        v2 = p * self.P8 / 32768.0
        return p + (v1 + v2 + self.P7) / 16.0

    def compensa_h(self, adc_h, t_fine):
        h = t_fine - 76800.0
        h = (adc_h - (self.H4 * 64.0 + self.H5 / 16384.0 * h)) * (
            self.H2 / 65536.0
            * (1.0 + self.H6 / 67108864.0 * h * (1.0 + self.H3 / 67108864.0 * h)))
        h = h * (1.0 - self.H1 * h / 524288.0)
        return max(0.0, min(100.0, h))


def punto_rugiada(t, rh):
    """Formula di Magnus (0..60 C)."""
    a, b = 17.62, 243.12
    g = math.log(max(rh, 0.1) / 100.0) + a * t / (b + t)
    return b * g / (a - g)


def ruota_log():
    try:
        with open(LOG, "r", errors="replace") as f:
            righe = f.readlines()
        if len(righe) > RIGHE_MAX:
            with open(LOG, "w") as f:
                f.writelines(righe[-RIGHE_MAX // 2:])
    except OSError:
        pass


def main():
    solo_test = "--test" in sys.argv
    s = Bme280()
    t, h, p = s.misura()
    ora = time.strftime("%Y-%m-%d %H:%M:%S")
    if h is None:
        riga = "%s T=%.1f RH=n/d P=%.1f DP=n/d (BMP280: manca l'umidita')" % (ora, t, p)
    else:
        dp = punto_rugiada(t, h)
        riga = "%s T=%.1f RH=%.1f P=%.1f DP=%.1f" % (ora, t, h, p, dp)
    print(riga)
    if solo_test:
        return
    ruota_log()
    with open(LOG, "a") as f:
        f.write(riga + "\n")
    if h is None:
        return
    # avviso con isteresi: scrive una sola volta finche' non rientra
    attivo = os.path.exists(STATO)
    if h >= SOGLIA_UMIDITA and not attivo:
        with open(EVENTI, "a") as f:
            f.write("%s UTC ALERT umidita %.0f%% T=%.1f\n"
                    % (time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()), h, t))
        open(STATO, "w").close()
    elif h < SOGLIA_UMIDITA - ISTERESI and attivo:
        os.remove(STATO)


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print("Errore I2C:", e, file=sys.stderr)
        sys.exit(1)
