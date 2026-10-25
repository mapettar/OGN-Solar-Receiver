#!/usr/bin/env python3
# calc_sunset.py v1.8 - calcolo tramonto senza librerie esterne
# v1.8: avvio SEMPRE alle 10:00 ora locale (estate e inverno) senza toccare lo sketch ATtiny:
#       il DS3231 non e piu in UTC puro ma in 'ora locale - 2 h' (= UTC in estate, UTC-1 in inverno),
#       cosi la soglia fissa 08:00 dello sketch cade sempre alle 10:00 locali.
#       --notte (cron, 5 min prima dello shutdown): se domani cambia l'ora legale/solare,
#       riscrive ora e allarme del DS3231 gia nella base di domani.
# - imposta lo shutdown nel crontab (tramonto - 90 min)
# - scrive nel registro allarme DS3231 l'ora di taglio del rele (tramonto - 88 min)
# - TETTO ASSOLUTO: shutdown max 16:55 UTC, taglio rele max 17:00 UTC (= 19:00 CEST)
# Uso:  python3 /boot/calc_sunset.py            (calcolo normale)
#       python3 /boot/calc_sunset.py --fallback (solo orari fissi, es. NTP assente)

import math
import datetime
import subprocess
import sys
from zoneinfo import ZoneInfo

# === CONFIGURAZIONE ===
LAT = 43.349721
LON = 12.773177
MARGINE_SHUTDOWN = 90          # minuti prima del tramonto: shutdown cron
MARGINE_RELE     = 88          # minuti prima del tramonto: taglio rele ATtiny
TETTO_SHUTDOWN   = (16, 55)    # UTC = 18:55 CEST
TETTO_RELE       = (17, 0)     # UTC = 19:00 CEST (deve coincidere con lo sketch ATtiny)
INIZIO_GIORNO    = 8           # valore DS3231: l'ATtiny accende quando il DS3231 segna 08:00
TZ_LOCALE        = ZoneInfo("Europe/Rome")
ORA_AVVIO_LOCALE = 10          # avvio voluto, ora locale
MARGINE_NOTTE    = 5           # minuti prima dello shutdown: riscrittura DS3231 se cambia l'ora
# Il DS3231 segna UTC + shift (shift = 0 con ora legale, -1 con ora solare). Le righe di cron controllano ogni minuto 'date -u':
# lo shutdown non dipende dal fuso con cui il demone cron legge il crontab.


def calcola_tramonto(lat, lon, data=None):
    """Ora del tramonto in UTC (ore decimali) oppure None."""
    if data is None:
        data = datetime.date.today()
    N = data.timetuple().tm_yday
    lng_ora = lon / 15.0
    t = N + (18 - lng_ora) / 24
    M = (0.9856 * t) - 3.289
    L = M + (1.916 * math.sin(math.radians(M))) + \
        (0.020 * math.sin(math.radians(2 * M))) + 282.634
    L = L % 360
    RA = math.degrees(math.atan(0.91764 * math.tan(math.radians(L)))) % 360
    Lquadrant = (math.floor(L / 90)) * 90
    RAquadrant = (math.floor(RA / 90)) * 90
    RA = (RA + (Lquadrant - RAquadrant)) / 15
    sinDec = 0.39782 * math.sin(math.radians(L))
    cosDec = math.cos(math.asin(sinDec))
    # zenith 90.833 gradi: cos = -0.01454 (manca nella v1.6: errore corretto)
    cosH = (-0.01454 - sinDec * math.sin(math.radians(lat))) / \
           (cosDec * math.cos(math.radians(lat)))
    if cosH > 1 or cosH < -1:
        return None
    H = math.degrees(math.acos(cosH)) / 15
    T = H + RA - (0.06571 * t) - 6.622
    return (T - lng_ora) % 24


def calcola_orari(data=None):
    """Restituisce dict con minuti-UTC-del-giorno (shutdown, failsafe, rele)."""
    tetto_sh = TETTO_SHUTDOWN[0] * 60 + TETTO_SHUTDOWN[1]
    tetto_re = TETTO_RELE[0] * 60 + TETTO_RELE[1]
    tr = calcola_tramonto(LAT, LON, data)
    if tr is None:
        sh, re, tramonto = tetto_sh, tetto_re, None
    else:
        tramonto = int(round(tr * 60))
        sh = min(tramonto - MARGINE_SHUTDOWN, tetto_sh)
        re = min(tramonto - MARGINE_RELE, tetto_re)
    # sanity: l'orario deve restare dopo l'accensione, altrimenti usa il tetto
    if sh <= INIZIO_GIORNO * 60 or re <= INIZIO_GIORNO * 60:
        sh, re = tetto_sh, tetto_re
    failsafe = min(sh + 60, tetto_re)       # secondo shutdown di sicurezza
    return {"tramonto": tramonto, "shutdown": sh, "failsafe": failsafe, "rele": re}


def shift_ore(quando):
    """Differenza DS3231 - UTC in ore: 0 con ora legale (CEST), -1 con ora solare (CET)."""
    off = quando.astimezone(TZ_LOCALE).utcoffset().total_seconds() / 3600
    return int(round(off)) - (ORA_AVVIO_LOCALE - INIZIO_GIORNO)


def shift_oggi():
    return shift_ore(datetime.datetime.now(datetime.timezone.utc))


def shift_domani():
    """Shift valido domattina alle 10:00 locali (tiene conto del cambio ora della notte)."""
    d = datetime.datetime.now(TZ_LOCALE).date() + datetime.timedelta(days=1)
    return shift_ore(datetime.datetime(d.year, d.month, d.day, ORA_AVVIO_LOCALE, 0, tzinfo=TZ_LOCALE))


def scrivi_ora_ds3231(shift):
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=shift)
    for reg, val in ((0x02, t.hour), (0x01, t.minute), (0x00, t.second)):
        subprocess.run(["i2cset", "-y", "1", "0x68", "0x%02x" % reg, "0x%02x" % dec2bcd(val)])


def dec2bcd(val):
    return ((val // 10) << 4) | (val % 10)


def hhmm(minuti):
    return "%02d:%02d" % (minuti // 60, minuti % 60)


def scrivi_allarme_ds3231(minuti_giorno, shift=0):
    ore, minuti = divmod(minuti_giorno + shift * 60, 60)
    for reg, val in ((0x07, 0x00), (0x08, dec2bcd(minuti)), (0x09, dec2bcd(ore))):
        subprocess.run(["i2cset", "-y", "1", "0x68", "0x%02x" % reg, "0x%02x" % val])


def riga_shutdown(minuti_giorno):
    """Riga di cron che scatta ogni minuto e spegne SOLO se l'ora UTC coincide.
    Il confronto usa 'date -u', quindi non dipende dal fuso orario del demone cron.
    Prima di spegnere scrive una riga in /boot/ogn-eventi.log (l'unico posto che
    sopravvive allo spegnimento: /tmp e /var/log sono in RAM)."""
    hhmm_utc = "%02d%02d" % (minuti_giorno // 60, minuti_giorno % 60)
    return ('* * * * * [ "$(date -u +\\%H\\%M)" = "' + hhmm_utc + '" ] && { echo "$(date -u \'+\\%F \\%T\') UTC shutdown '
            + hhmm_utc + '" >> /boot/ogn-eventi.log; sync; /sbin/shutdown -h now; }')


def riga_notte(minuti_giorno):
    """Riga di cron: 5 minuti prima dello shutdown riallinea il DS3231 alla base di domani."""
    hhmm_utc = "%02d%02d" % (minuti_giorno // 60, minuti_giorno % 60)
    return ('* * * * * [ "$(date -u +\\%H\\%M)" = "' + hhmm_utc
            + '" ] && /usr/bin/python3 /usr/local/sbin/calc_sunset.py --notte >> /var/log/ogn-boot-setup.log 2>&1')


def prepara_notte():
    oggi, domani = shift_oggi(), shift_domani()
    if oggi == domani:
        print("--notte: nessun cambio ora, DS3231 invariato (shift %d)" % oggi)
        return
    o = calcola_orari()
    scrivi_ora_ds3231(domani)
    scrivi_allarme_ds3231(o["rele"], domani)
    ev = "%s UTC cambio ora: DS3231 riscritto con shift %d (domani avvio ore %d locali)" % (
        datetime.datetime.now(datetime.timezone.utc).strftime("%F %T"), domani, ORA_AVVIO_LOCALE)
    with open("/boot/ogn-eventi.log", "a") as f:
        f.write(ev + "\n")
    print(ev)


def aggiorna_crontab(o):
    r = subprocess.run(["crontab", "-u", "root", "-l"], capture_output=True, text=True)
    linee = [l for l in r.stdout.split("\n") if l.strip() and "shutdown" not in l and "--notte" not in l]
    linee.append(riga_notte(o["shutdown"] - MARGINE_NOTTE))
    linee.append(riga_shutdown(o["shutdown"]))
    linee.append(riga_shutdown(o["failsafe"]))
    # cintura di sicurezza: tetto fisso 17:00 UTC (19:00 CEST) sempre presente
    linee.append(riga_shutdown(TETTO_RELE[0] * 60 + TETTO_RELE[1]))
    uniche = []
    for l in linee:               # niente righe duplicate
        if l not in uniche:
            uniche.append(l)
    subprocess.run(["crontab", "-u", "root", "-"], input="\n".join(uniche) + "\n", text=True)


if __name__ == "__main__":
    if "--shift" in sys.argv:
        print(shift_oggi())
        sys.exit(0)
    if "--notte" in sys.argv:
        prepara_notte()
        sys.exit(0)
    if "--fallback" in sys.argv:
        o = {"tramonto": None,
             "shutdown": TETTO_SHUTDOWN[0] * 60 + TETTO_SHUTDOWN[1],
             "failsafe": TETTO_RELE[0] * 60 + TETTO_RELE[1],
             "rele": TETTO_RELE[0] * 60 + TETTO_RELE[1]}
        print("Modalita fallback: orari fissi")
    else:
        o = calcola_orari()
    aggiorna_crontab(o)
    scrivi_allarme_ds3231(o["rele"], shift_oggi())
    print("Shift DS3231:     %d h rispetto a UTC" % shift_oggi())
    print("Tramonto UTC:      %s" % (hhmm(o["tramonto"]) if o["tramonto"] else "n/d"))
    print("Shutdown cron UTC: %s" % hhmm(o["shutdown"]))
    print("Failsafe UTC:      %s" % hhmm(o["failsafe"]))
    print("Taglio rele UTC:   %s" % hhmm(o["rele"]))
