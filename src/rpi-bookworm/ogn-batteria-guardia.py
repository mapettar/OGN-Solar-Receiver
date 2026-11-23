#!/usr/bin/env python3
# ogn-batteria-guardia.py v1.3 - spegnimento PULITO a batteria bassa (Raspberry Pi 3A+ con ATtiny + DS3231)
#
# Problema: a batteria bassa l'ATtiny apre il rele (circa 9,6 V) senza avvisare la Pi: taglio brusco, rischio per la SD.
# L'ATtiny non puo' dire niente alla Pi, ma legge l'ALLARME del DS3231 (registri 0x07-0x09) e taglia a quell'ora.
# Questo script, lanciato dal cron, fa lo stesso lavoro della sera: scrive nell'allarme "ora + 3 minuti" e
# poi esegue 'shutdown -h now'. L'ATtiny taglia a Pi gia' ferma. Lo sketch v1.7.4 non va toccato.
#
# Due modi:
#   ogn-batteria-guardia.py           controllo periodico (cron ogni minuto): pacco sotto BATTERIA_SOGLIA_V per
#                                     BATTERIA_MINUTI minuti di fila e senza carica -> spegnimento pulito
#   ogn-batteria-guardia.py --avvio   controllo unico dopo l'avvio (cron @reboot): attende 3 minuti e, se il pacco
#                                     sotto carico e' sotto BATTERIA_SOGLIA_AVVIO_V, spegne (non vale la pena
#                                     partire con pochi Wh: il pacco non regge nemmeno mezza giornata)
#   --spegni [--forza]                spegnimento pulito subito (allarme + attesa + shutdown); prima delle 08:57 del DS3231
#                                     rifiuta, a meno di --forza
#   --simula V                        non legge l'INA219: usa V come tensione e non spegne mai (solo prova a video)
#
# Impostazioni (in /etc/default/ogn-boot-setup oppure variabili d'ambiente):
#   BATTERIA_GUARDIA=on|prova|off     (predefinito on; prova = scrive solo cosa avrebbe fatto in ogn-eventi.log)
#   BATTERIA_SOGLIA_V=10.3            soglia del controllo periodico (V, sotto carico)
#   BATTERIA_SOGLIA_AVVIO_V=11.0      soglia del controllo all'avvio
#   BATTERIA_MINUTI=3                 minuti consecutivi sotto soglia
#   BATTERIA_CARICA_MA=300            con una carica oltre questa corrente non spegne (il pacco sta risalendo)
#
# v1.1 (22 nov 2026): dopo 'shutdown' la Pi in halt viene RISVEGLIATA dall'ATtiny, che ogni 30 s legge il DS3231
# e tira SCL a massa (~45 s). Non si ferma mai da sola se l'ATtiny non e' gia' in "silenzio I2C", cioe' negli ultimi
# 3 minuti prima del taglio. Percio' lo script (1) scrive l'allarme a ora+3 minuti, (2) aspetta 40 s perche'
# l'ATtiny legga l'allarme ed entri in silenzio, (3) solo allora fa 'shutdown'. Se l'ora del DS3231 e' prima delle
# 08:57 l'ATtiny ignora l'allarme (ora <= 8): v1.1 portava l'orologio del DS3231 a 08:57, ma il giorno dopo la
# stazione partiva in anticipo e, quando ogn-boot-setup rimetteva il DS3231 all'ora giusta (< 08:00), l'ATtiny
# tagliava il rele a meta avvio (23 nov 2026). v1.2: prima delle 08:57 del DS3231 NON spegne e riprova al minuto dopo
# (la stazione resta accesa fino ad allora; l'ATtiny la taglia comunque a 9,6 V). 'shutdown' compare nella riga di
# evento perche' 'stato' cerca quella parola per riconoscere lo spegnimento della sera.
# v1.3 (23 nov 2026): il PATH di cron e' solo /usr/bin:/bin, senza /usr/sbin dove sta i2cget: da cron l'allarme non
# veniva scritto e la Pi, spenta senza allarme, era risvegliata dall'ATtiny (14 cicli di riavvio in un'ora). Ora lo
# script imposta il PATH da solo e, se l'allarme non si scrive, NON spegne (scrive l'errore nel log una volta).
# --forza (solo con --spegni) ripete il vecchio metodo dell'orologio spostato, con quel difetto del giorno dopo.
#
# Il DS3231 segna UTC + shift (0 con ora legale, -1 con ora solare): l'allarme si scrive nella STESSA base dell'ora
# letta dal DS3231, quindi basta leggerla e sommare 3 minuti. L'ATtiny considera "nessun allarme" (taglio alle
# 17:00 del DS3231) un'ora uguale o minore di 8: per questo l'allarme non e' mai prima delle 09:00.
# Letture dell'INA219 fuori da 8-14 V (bus I2C bloccato, 0.000 V) non contano mai: non si spegne per un'errata lettura.
import os
os.environ["PATH"] = "/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"      # cron ha solo /usr/bin:/bin
import shlex
import subprocess
import sys
import time

CONF = os.environ.get("CONF", "/etc/default/ogn-boot-setup")
EVENTI = os.environ.get("EVENTI", "/boot/ogn-eventi.log")
STATODIR = os.environ.get("STATODIR", "/run/ogn-batteria-guardia")
UPTIME_FILE = os.environ.get("UPTIME_FILE", "/proc/uptime")
MONITOR = shlex.split(os.environ.get("MONITOR_CMD", "/usr/local/sbin/monitor_batteria.py"))
I2CGET = shlex.split(os.environ.get("I2CGET_CMD", "i2cget"))
I2CSET = shlex.split(os.environ.get("I2CSET_CMD", "i2cset"))
SHUTDOWN = shlex.split(os.environ.get("SHUTDOWN_CMD", "/sbin/shutdown -h now"))
ATTESA_AVVIO = int(os.environ.get("AVVIO_ATTESA", "180"))
ATTESA_ARRESTO = int(os.environ.get("ARRESTO_MINUTI", "3"))
ATTESA_SILENZIO = int(os.environ.get("SILENZIO_S", "40"))
V_MIN_VALIDA, V_MAX_VALIDA = 8.0, 14.0
ORA_MINIMA_ALLARME = 9      # l'ATtiny ignora un allarme con ora <= 8 (ORA_ACCENSIONE)


def leggi_conf():
    c = {}
    try:
        with open(CONF) as f:
            for riga in f:
                riga = riga.strip()
                if not riga or riga.startswith("#") or "=" not in riga:
                    continue
                k, v = riga.split("=", 1)
                c[k.strip()] = v.split("#")[0].strip().strip('"').strip("'")
    except OSError:
        pass
    return c


CFG = leggi_conf()


def opz(chiave, predefinito):
    return os.environ.get(chiave) or CFG.get(chiave) or predefinito


def esegui(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def evento(testo):
    riga = "%s UTC batteria-guardia %s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()), testo)
    print(riga)
    try:
        with open(EVENTI, "a") as f:
            f.write(riga + "\n")
    except OSError:
        pass


def leggi_pacco():
    """(tensione V, corrente mA) del pacco, dall'INA219 0x40; None se manca o e' fuori scala."""
    try:
        r = esegui(MONITOR + ["--pacco", "3s-liion", "--csv"])
        campi = r.stdout.strip().split(",")
        v, ma = float(campi[1]), float(campi[2])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None
    if not (V_MIN_VALIDA <= v <= V_MAX_VALIDA):
        return None
    return v, ma


def leggi_carica():
    """Corrente di carica in mA dal secondo INA219 (0x41); 0 se non risponde."""
    try:
        r = esegui(MONITOR + ["--addr", "0x41", "--carica", "--csv"])
        return float(r.stdout.strip().split(",")[2])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return 0.0


def leggi_ds(reg):
    r = esegui(I2CGET + ["-y", "1", "0x68", "0x%02x" % reg])
    return int(r.stdout.strip(), 16)


def bcd(b):
    return ((b >> 4) * 10) + (b & 0x0F)


def dec2bcd(n):
    return ((n // 10) << 4) | (n % 10)


def scrivi_reg(reg, val):
    esegui(I2CSET + ["-y", "1", "0x68", "0x%02x" % reg, "0x%02x" % val])


def scrivi_allarme(forza=False):
    """Allarme DS3231 = ora attuale + ATTESA_ARRESTO minuti. Ritorna una descrizione, 'PRESTO' se e' prima delle
    08:57 del DS3231 (l'ATtiny ignora un allarme con ora <= 8: non si scrive niente), o None se non scritto.
    Con forza=True, prima delle 08:57 allarme 09:00 e orologio del DS3231 portato a 08:57:00."""
    try:
        ore = bcd(leggi_ds(0x02) & 0x3F)
        minuti = bcd(leggi_ds(0x01) & 0x7F)
        tot = ore * 60 + minuti + ATTESA_ARRESTO
        if tot >= 24 * 60:
            return None
        if tot < ORA_MINIMA_ALLARME * 60 and not forza:
            return "PRESTO"
        if tot < ORA_MINIMA_ALLARME * 60:
            for reg, val in ((0x07, 0x00), (0x08, 0x00), (0x09, dec2bcd(ORA_MINIMA_ALLARME))):
                scrivi_reg(reg, val)
            for reg, val in ((0x00, 0x00), (0x01, dec2bcd(60 - ATTESA_ARRESTO)), (0x02, dec2bcd(ORA_MINIMA_ALLARME - 1))):
                scrivi_reg(reg, val)
            return "%02d:00 (orologio del DS3231 portato alle %02d:%02d:00, si riallinea al prossimo avvio)" % (
                ORA_MINIMA_ALLARME, ORA_MINIMA_ALLARME - 1, 60 - ATTESA_ARRESTO)
        hh, mm = tot // 60, tot % 60
        for reg, val in ((0x07, 0x00), (0x08, dec2bcd(mm)), (0x09, dec2bcd(hh))):
            scrivi_reg(reg, val)
        return "%02d:%02d" % (hh, mm)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def arresta(motivo, modo, forza=False):
    if modo == "prova":
        evento("PROVA: avrei spento la Pi (%s)" % motivo)
        return
    al = scrivi_allarme(forza)
    if al == "PRESTO":
        # prima delle 08:57 del DS3231 un allarme non e' valido per l'ATtiny: si resta accesi e si riprova
        os.makedirs(STATODIR, exist_ok=True)
        seg = os.path.join(STATODIR, "presto")
        print("prima delle 08:57 del DS3231 non spengo (l'ATtiny ignorerebbe l'allarme); con --spegni --forza si sposta l'orologio")
        if not os.path.exists(seg):
            open(seg, "w").close()
            evento("pacco basso (%s) ma il DS3231 e' prima delle 08:57: non spengo, riprovo ogni minuto" % motivo)
        return
    if not al:
        # senza allarme l'ATtiny risveglierebbe la Pi dopo ~45 s: un ciclo di riavvii inutile. Meglio non spegnere.
        os.makedirs(STATODIR, exist_ok=True)
        seg = os.path.join(STATODIR, "errore-allarme")
        print("allarme DS3231 non scritto (i2cget/i2cset non trovati o bus I2C in errore): NON spengo")
        if not os.path.exists(seg):
            open(seg, "w").close()
            evento("ERRORE (%s): allarme DS3231 non scritto, NON spengo la Pi (verrebbe risvegliata dall'ATtiny)" % motivo)
        return
    evento("shutdown pulito (%s): taglio del rele alle %s (ora DS3231)" % (motivo, al))
    if al:
        time.sleep(ATTESA_SILENZIO)       # l'ATtiny deve leggere l'allarme ed entrare in silenzio I2C prima dell'halt
    try:
        esegui(["sync"])
    except (OSError, subprocess.SubprocessError):
        pass
    subprocess.run(SHUTDOWN)


def uptime_s():
    try:
        with open(UPTIME_FILE) as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 1e9


def main():
    args = sys.argv[1:]
    if "--spegni" in args:                        # spegnimento pulito su richiesta, sempre reale (anche con BATTERIA_GUARDIA=prova)
        arresta("richiesta manuale", "on", forza="--forza" in args)
        return
    simula = None
    if "--simula" in args:
        simula = float(args[args.index("--simula") + 1])
    modo = opz("BATTERIA_GUARDIA", "on")
    if modo == "off":
        return
    if simula is not None:
        modo = "prova"
    soglia = float(opz("BATTERIA_SOGLIA_V", "10.3"))
    soglia_avvio = float(opz("BATTERIA_SOGLIA_AVVIO_V", "11.0"))
    minuti = int(opz("BATTERIA_MINUTI", "3"))
    carica_max = float(opz("BATTERIA_CARICA_MA", "300"))

    def pacco():
        return (simula, 0.0) if simula is not None else leggi_pacco()

    if "--avvio" in args:
        if simula is None:
            time.sleep(ATTESA_AVVIO)
        p = pacco()
        if p is None:
            return
        v = p[0]
        if v < soglia_avvio and (simula is not None or leggi_carica() < carica_max):
            arresta("all'avvio il pacco e' a %.3f V, sotto %.1f V" % (v, soglia_avvio), modo)
        else:
            print("avvio: pacco %.3f V, soglia %.1f V: niente da fare" % (v, soglia_avvio))
        return

    # controllo periodico
    if simula is None and uptime_s() < 240:
        return                                    # nei primi 4 minuti decide il controllo all'avvio
    p = pacco()
    if p is None:
        return                                    # lettura mancante o assurda: non conta
    v = p[0]
    os.makedirs(STATODIR, exist_ok=True)
    f_cont = os.path.join(STATODIR, "contatore")
    try:
        with open(f_cont) as f:
            n = int(f.read().strip() or "0")
    except (OSError, ValueError):
        n = 0
    if simula is not None:
        n = minuti if v < soglia else 0
    elif v < soglia and leggi_carica() < carica_max:
        n += 1
    else:
        n = 0
    if simula is None:
        with open(f_cont, "w") as f:
            f.write(str(n))
    if n >= minuti:
        arresta("pacco a %.3f V sotto %.1f V da %d minuti" % (v, soglia, n), modo)
    else:
        print("pacco %.3f V, soglia %.1f V, minuti sotto soglia %d di %d" % (v, soglia, n, minuti))


if __name__ == "__main__":
    main()
