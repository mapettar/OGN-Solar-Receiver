#!/usr/bin/env python3
# ogn_sim.py v1.1 - collegamento a internet via SIM (Waveshare SIM7080G HAT, LTE-M) con PPP.
# v1.1: la strada predefinita via ppp0 la mette questo servizio (pppd con defaultroute non sostituisce una strada
#       gia' presente, come quella del Wi-Fi): metrica 700 se il Wi-Fi da' internet, 50 se non lo da'.
# Servizio systemd (ogn-sim.service). Fa queste cose, in ordine:
#   1) controlla se il modulo risponde ad AT sulla seriale; se no, gli da' l'impulso su PWRKEY (GPIO4, serve il
#      ponticello PWR-P7 sulla HAT) e riprova (al massimo due impulsi: l'impulso INVERTE lo stato del modulo);
#   2) imposta LTE-M e l'APN, aspetta la registrazione alla rete;
#   3) lancia pppd (/etc/ppp/peers/simbase) e controlla che il traffico passi (ping su ppp0);
#   4) se il PPP cade o non passa traffico lo rilancia; dopo tre cicli falliti spegne e riaccende il modulo.
# Modi (SIM_MODE in /etc/default/ogn-sim):
#   off     non fa niente (il servizio non parte)
#   auto    la SIM si usa solo se il Wi-Fi non da' internet per SIM_WIFI_GRACE secondi; quando il Wi-Fi torna
#           per SIM_WIFI_BACK secondi, il PPP si chiude. Con il Wi-Fi buono il modulo non viene nemmeno acceso.
#   always  il PPP resta sempre su; il Wi-Fi, se c'e', passa avanti (metrica piu' bassa).
# Stato leggibile da "stato": /run/ogn-sim/stato.json. Eventi: /boot/ogn-eventi.log (righe "sim ...").
# Dati scambiati sulla SIM: /var/lib/ogn-sim/dati-AAAA-MM-GG (byte ricevuti e inviati, dal contatore di ppp0).
# Variabili per le prove: OGN_SIM_CONF, OGN_SIM_DEV, PPPD_CMD, PINCTRL_CMD, PING_CMD, IP_CMD, STATEDIR, DATADIR,
# EVENTI, RESOLV, TICK (secondi tra due giri, default 10), SYSNET.
import json
import os
import re
import signal
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    sys.stderr.write("ogn_sim: manca python3-serial (sudo apt install python3-serial)\n")
    sys.exit(2)

VERSIONE = "1.1"
CONF = os.environ.get("OGN_SIM_CONF", "/etc/default/ogn-sim")
DEV = os.environ.get("OGN_SIM_DEV", "/dev/serial0")
PPPD = os.environ.get("PPPD_CMD", "pppd")
PINCTRL = os.environ.get("PINCTRL_CMD", "pinctrl")
PING = os.environ.get("PING_CMD", "ping")
IPCMD = os.environ.get("IP_CMD", "ip")
STATEDIR = os.environ.get("STATEDIR", "/run/ogn-sim")
DATADIR = os.environ.get("DATADIR", "/var/lib/ogn-sim")
EVENTI = os.environ.get("EVENTI", "/boot/ogn-eventi.log")
RESOLV = os.environ.get("RESOLV", "/etc/resolv.conf")
SYSNET = os.environ.get("SYSNET", "/sys/class/net")
TICK = float(os.environ.get("TICK", "10"))

DEFAULTS = {
    "SIM_MODE": "off",            # off | auto | always
    "SIM_APN": "simbase",
    "SIM_RAT": "ltem",            # ltem | nbiot | both
    "SIM_BAUD": "57600",          # velocita' provata per prima (il modulo la riconosce da solo)
    "SIM_PWR_PIN": "4",           # GPIO BCM del PWRKEY (ponticello PWR-P7)
    "SIM_PWR_ACTIVE": "high",     # livello che preme il tasto: high | low
    "SIM_PWR_PULSE": "1.5",       # secondi di impulso
    "SIM_WIFI_IF": "wlan0",
    "SIM_PING_HOST": "1.1.1.1",
    "SIM_WIFI_GRACE": "90",       # secondi di Wi-Fi senza internet prima di passare alla SIM (auto)
    "SIM_WIFI_BACK": "300",       # secondi di Wi-Fi di nuovo buono prima di chiudere il PPP (auto)
    "SIM_REG_TIMEOUT": "240",     # attesa registrazione alla rete
    "SIM_CHECK_EVERY": "60",      # secondi tra due prove di traffico su ppp0
    "SIM_FAIL_MAX": "4",          # prove consecutive fallite prima di rilanciare il PPP
    "SIM_RETRY": "300",           # attesa dopo un tentativo fallito
    "SIM_DNS": "1.1.1.1 8.8.8.8", # scritti in resolv.conf solo quando il Wi-Fi non c'e'
    "SIM_DNS_MODE": "write",      # write | none
}


def leggi_conf():
    cfg = dict(DEFAULTS)
    try:
        with open(CONF) as f:
            for riga in f:
                riga = riga.strip()
                if not riga or riga.startswith("#") or "=" not in riga:
                    continue
                k, v = riga.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return cfg


def ora_utc():
    return time.strftime("%F %T", time.gmtime())


def evento(msg):
    try:
        with open(EVENTI, "a") as f:
            f.write("%s UTC sim %s\n" % (ora_utc(), msg))
    except OSError:
        pass
    print("sim:", msg, flush=True)


def esegui(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, str(e)


class Modem:
    """Comandi AT sulla seriale. Non resta aperta mentre gira pppd."""

    def __init__(self, dev):
        self.dev = dev
        self.s = None
        self.baud = None

    def apri(self, baud):
        self.chiudi()
        self.s = serial.Serial(self.dev, int(baud), timeout=0.2)
        self.baud = int(baud)

    def chiudi(self):
        if self.s is not None:
            try:
                self.s.close()
            except OSError:
                pass
        self.s = None

    def at(self, cmd, timeout=3.0):
        """Invia un comando e legge fino a OK/ERROR. Ritorna (ok, testo)."""
        self.s.reset_input_buffer()
        self.s.write(cmd.encode() + b"\r\n")
        fine = time.time() + timeout
        buf = ""
        while time.time() < fine:
            dati = self.s.read(256)
            if dati:
                buf += dati.decode(errors="replace")
                righe = [r.strip() for r in buf.replace("\r", "\n").split("\n")]
                if "OK" in righe:
                    return True, buf.strip()
                if any(r == "ERROR" or r.startswith("+CME ERROR") or r.startswith("+CMS ERROR") for r in righe):
                    return False, buf.strip()
        return False, buf.strip()

    def risponde(self, baud, tentativi=3):
        """Il modulo riconosce la velocita' dai primi caratteri: i primi AT possono andare persi."""
        try:
            self.apri(baud)
        except (OSError, serial.SerialException, ValueError):
            return False
        for _ in range(tentativi):
            ok, _ = self.at("AT", 1.0)
            if ok:
                return True
        return False


def impulso_pwrkey(cfg):
    pin = cfg["SIM_PWR_PIN"]
    attivo = "dh" if cfg["SIM_PWR_ACTIVE"] == "high" else "dl"
    riposo = "dl" if attivo == "dh" else "dh"
    esegui([PINCTRL, "set", pin, "op", attivo])
    time.sleep(float(cfg["SIM_PWR_PULSE"]))
    esegui([PINCTRL, "set", pin, "op", riposo])


def velocita_da_provare(cfg):
    ordine = [cfg["SIM_BAUD"], "115200", "57600", "9600"]
    visti = []
    for b in ordine:
        if b not in visti:
            visti.append(b)
    return visti


def trova_modulo(modem, cfg):
    for b in velocita_da_provare(cfg):
        if modem.risponde(b):
            return int(b)
    return None


def accendi_modulo(modem, cfg, st):
    """Ritorna la velocita' se il modulo risponde. Al massimo due impulsi (l'impulso inverte lo stato)."""
    b = trova_modulo(modem, cfg)
    if b:
        return b
    for n in (1, 2):
        evento("modulo muto, impulso PWRKEY %d di 2" % n)
        st["impulsi"] = st.get("impulsi", 0) + 1
        impulso_pwrkey(cfg)
        fine = time.time() + 30
        while time.time() < fine:
            time.sleep(3)
            b = trova_modulo(modem, cfg)
            if b:
                evento("modulo acceso e risponde (seriale a %d)" % b)
                return b
    return None


def configura(modem, cfg):
    rat = {"ltem": "1", "nbiot": "2", "both": "3"}.get(cfg["SIM_RAT"], "1")
    for cmd in ("ATE0", "AT+CFUN=1", "AT+CNMP=38", "AT+CMNB=" + rat,
                'AT+CGDCONT=1,"IP","%s"' % cfg["SIM_APN"]):
        modem.at(cmd, 5.0)


def interpreta_cpsi(testo):
    """+CPSI: LTE CAT-M1,Online,222-10,0x7D06,14883105,278,EUTRAN-BAND3,1850,5,5,-11,-109,-85,12"""
    m = re.search(r"\+CPSI:\s*([^\r\n]+)", testo)
    if not m:
        return {}
    p = [x.strip() for x in m.group(1).split(",")]
    info = {"tecnologia": p[0] if p else ""}
    if len(p) > 2:
        info["rete"] = p[2]
    if len(p) > 6:
        info["banda"] = p[6]
    if len(p) > 11:
        try:
            info["rsrq"] = int(p[10])
            info["rsrp"] = int(p[11])
        except ValueError:
            pass
    return info


def registrato(modem):
    ok, t = modem.at("AT+CEREG?", 3.0)
    m = re.search(r"\+CEREG:\s*\d+,(\d+)", t)
    return (m is not None and m.group(1) in ("1", "5")), (m.group(1) if m else "?")


def raccogli_info(modem, st):
    ok, t = modem.at("AT+CSQ", 3.0)
    m = re.search(r"\+CSQ:\s*(\d+),", t)
    if m:
        st["csq"] = int(m.group(1))
    ok, t = modem.at("AT+COPS?", 3.0)
    m = re.search(r'\+COPS:\s*\d+,\d+,"([^"]*)"', t)
    if m:
        st["operatore"] = m.group(1)
    ok, t = modem.at("AT+CPSI?", 4.0)
    st.update(interpreta_cpsi(t))


def attendi_registrazione(modem, cfg, st):
    fine = time.time() + int(cfg["SIM_REG_TIMEOUT"])
    stat = "?"
    while time.time() < fine:
        ok, stat = registrato(modem)
        st["cereg"] = stat
        if ok:
            raccogli_info(modem, st)
            return True
        if stat == "3":
            time.sleep(15)      # negata: la rete a volte ci ripensa dopo un po'
        else:
            time.sleep(5)
    return False


def indirizzo_iface(nome):
    rc, out = esegui([IPCMD, "-4", "-o", "addr", "show", "dev", nome], 5)
    m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if rc == 0 and m else None


def ping_su(iface, host, attesa=10):
    rc, _ = esegui([PING, "-c", "1", "-W", str(attesa), "-I", iface, host], attesa + 5)
    return rc == 0


def contatori(iface):
    try:
        rx = int(open("%s/%s/statistics/rx_bytes" % (SYSNET, iface)).read())
        tx = int(open("%s/%s/statistics/tx_bytes" % (SYSNET, iface)).read())
        return rx, tx
    except (OSError, ValueError):
        return None


class Servizio:
    def __init__(self):
        self.cfg = leggi_conf()
        self.modem = Modem(DEV)
        self.ppp = None
        self.ppp_da = None
        self.baud = None
        self.wifi_male_da = None
        self.wifi_bene_da = None
        self.prove_fallite = 0
        self.cicli_falliti = 0
        self.prossimo_tentativo = 0
        self.ultima_prova = 0
        self.st = {"versione": VERSIONE, "fase": "avvio", "ppp_riavvii": 0, "modulo_riavvii": 0}
        self.dns_salvato = False
        self.wifi = False
        self.metrica_strada = None
        self.cont_prec = None
        self.terminato = False
        os.makedirs(STATEDIR, exist_ok=True)
        os.makedirs(DATADIR, exist_ok=True)

    # ---- stato su file -----------------------------------------------------------------
    def scrivi_stato(self):
        self.st["aggiornato"] = int(time.time())
        self.st["modo"] = self.cfg["SIM_MODE"]
        self.st["ppp_su"] = bool(self.ppp and self.ppp.poll() is None and indirizzo_iface("ppp0"))
        self.st["ppp_ip"] = indirizzo_iface("ppp0") if self.st["ppp_su"] else None
        self.st["ppp_da"] = int(self.ppp_da) if (self.st["ppp_su"] and self.ppp_da) else None
        p = os.path.join(STATEDIR, "stato.json")
        try:
            with open(p + ".tmp", "w") as f:
                json.dump(self.st, f)
            os.replace(p + ".tmp", p)
        except OSError:
            pass

    def conta_dati(self):
        c = contatori("ppp0")
        if c is None:
            self.cont_prec = None
            return
        if self.cont_prec is not None:
            drx, dtx = c[0] - self.cont_prec[0], c[1] - self.cont_prec[1]
            if drx < 0 or dtx < 0:          # contatore ripartito da zero
                drx, dtx = c
            p = os.path.join(DATADIR, "dati-" + time.strftime("%F", time.gmtime()))
            try:
                rx0, tx0 = (int(x) for x in open(p).read().split())
            except (OSError, ValueError):
                rx0 = tx0 = 0
            try:
                with open(p, "w") as f:
                    f.write("%d %d\n" % (rx0 + drx, tx0 + dtx))
            except OSError:
                pass
        self.cont_prec = c

    # ---- DNS -----------------------------------------------------------------------------
    def dns_scrivi(self):
        if self.cfg["SIM_DNS_MODE"] != "write" or self.dns_salvato:
            return
        try:
            orig = open(RESOLV).read() if os.path.exists(RESOLV) else ""
            with open(os.path.join(STATEDIR, "resolv.orig"), "w") as f:
                f.write(orig)
            with open(RESOLV, "w") as f:
                f.write("# scritto da ogn_sim.py mentre la rete e' la SIM\n")
                for ns in self.cfg["SIM_DNS"].split():
                    f.write("nameserver %s\n" % ns)
            self.dns_salvato = True
            evento("DNS scritti in resolv.conf (rete = SIM)")
        except OSError as e:
            evento("DNS: scrittura fallita (%s)" % e)

    def dns_ripristina(self):
        if not self.dns_salvato:
            return
        try:
            orig = open(os.path.join(STATEDIR, "resolv.orig")).read()
            with open(RESOLV, "w") as f:
                f.write(orig)
            evento("DNS ripristinati in resolv.conf")
        except OSError as e:
            evento("DNS: ripristino fallito (%s)" % e)
        self.dns_salvato = False

    # ---- Wi-Fi ---------------------------------------------------------------------------
    def wifi_ok(self):
        ifname = self.cfg["SIM_WIFI_IF"]
        if not os.path.isdir(os.path.join(SYSNET, ifname)):
            return False
        return ping_su(ifname, self.cfg["SIM_PING_HOST"], 3)

    # ---- PPP -----------------------------------------------------------------------------
    def ppp_ferma(self, motivo):
        if self.ppp is not None:
            try:
                self.ppp.terminate()
                try:
                    self.ppp.wait(10)
                except subprocess.TimeoutExpired:
                    self.ppp.kill()
                    self.ppp.wait(5)
            except OSError:
                pass
            evento("PPP chiuso (%s)" % motivo)
        self.ppp = None
        self.ppp_da = None
        self.cont_prec = None
        self.metrica_strada = None
        self.dns_ripristina()
        self.st["fase"] = "ppp spento"

    def ppp_avvia(self, metrica):
        self.modem.chiudi()
        cmd = [PPPD, DEV, str(self.baud), "call", "simbase", "nodetach"]
        log = open(os.path.join(STATEDIR, "pppd.log"), "ab")
        self.ppp = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        fine = time.time() + 90
        while time.time() < fine:
            if self.ppp.poll() is not None:
                evento("pppd terminato subito (codice %s)" % self.ppp.returncode)
                self.ppp = None
                return False
            if indirizzo_iface("ppp0"):
                self.ppp_da = time.time()
                return True
            time.sleep(2)
        evento("pppd senza indirizzo dopo 90 s")
        self.ppp_ferma("nessun indirizzo")
        return False

    def imposta_strada(self, metrica):
        """Strada predefinita via ppp0 con la metrica voluta (sparisce da sola con l'interfaccia)."""
        if self.metrica_strada == metrica:
            return
        rc, out = esegui([IPCMD, "route", "replace", "default", "dev", "ppp0", "metric", str(metrica)], 5)
        if rc == 0:
            self.metrica_strada = metrica
            evento("strada predefinita via ppp0, metrica %s (%s)" %
                   (metrica, "SIM davanti al Wi-Fi" if metrica < 100 else "Wi-Fi davanti, SIM di riserva"))
        else:
            evento("strada via ppp0 non impostata: %s" % out.strip()[:120])

    def sale(self, metrica):
        """Modulo -> rete -> PPP. Ritorna True se il PPP e' su e passa traffico."""
        self.st["fase"] = "accendo il modulo"
        self.scrivi_stato()
        self.baud = accendi_modulo(self.modem, self.cfg, self.st)
        if not self.baud:
            evento("il modulo non risponde (ponticello PWR-P7 montato? HAT collegata?)")
            self.modem.chiudi()
            return False
        self.st["fase"] = "registrazione"
        self.scrivi_stato()
        configura(self.modem, self.cfg)
        if not attendi_registrazione(self.modem, self.cfg, self.st):
            evento("nessuna registrazione alla rete entro %s s (CEREG %s)" %
                   (self.cfg["SIM_REG_TIMEOUT"], self.st.get("cereg")))
            self.modem.chiudi()
            return False
        evento("registrato: %s %s, CSQ %s, RSRP %s" % (self.st.get("operatore", "?"),
               self.st.get("tecnologia", "?"), self.st.get("csq", "?"), self.st.get("rsrp", "?")))
        self.st["fase"] = "ppp in avvio"
        self.scrivi_stato()
        if not self.ppp_avvia(metrica):
            return False
        if not ping_su("ppp0", self.cfg["SIM_PING_HOST"], 20):
            evento("PPP su (%s) ma il ping non passa" % indirizzo_iface("ppp0"))
            self.ppp_ferma("ping non passa")
            return False
        self.metrica_strada = None
        self.imposta_strada(metrica)
        evento("PPP su, indirizzo %s" % indirizzo_iface("ppp0"))
        self.st["fase"] = "ppp su"
        self.st["ultimo_ping_ok"] = int(time.time())
        self.ultima_prova = time.time()
        self.prove_fallite = 0
        return True

    def reset_modulo(self):
        evento("reset del modulo (cicli falliti: %d)" % self.cicli_falliti)
        self.st["modulo_riavvii"] += 1
        try:
            self.modem.apri(self.baud or int(self.cfg["SIM_BAUD"]))
            self.modem.at("AT+CPOWD=1", 5.0)
        except (OSError, serial.SerialException):
            pass
        self.modem.chiudi()
        time.sleep(10)

    # ---- ciclo principale ----------------------------------------------------------------
    def serve_ppp(self):
        """Decide se la SIM deve essere in uso. Ritorna (serve, metrica)."""
        modo = self.cfg["SIM_MODE"]
        ora = time.time()
        self.wifi = self.wifi_ok() if modo in ("auto", "always") else False
        self.st["wifi_ok"] = self.wifi
        if modo == "always":
            return True, (700 if self.wifi else 50)
        if modo != "auto":
            return False, 700
        if self.wifi:
            self.wifi_male_da = None
            if self.wifi_bene_da is None:
                self.wifi_bene_da = ora
            if self.ppp is not None and ora - self.wifi_bene_da >= int(self.cfg["SIM_WIFI_BACK"]):
                return False, 700
            return (self.ppp is not None), 700
        self.wifi_bene_da = None
        if self.wifi_male_da is None:
            self.wifi_male_da = ora
        return (ora - self.wifi_male_da >= int(self.cfg["SIM_WIFI_GRACE"]) or self.ppp is not None), 50

    def giro(self):
        self.cfg = leggi_conf()
        serve, metrica = self.serve_ppp()
        ora = time.time()
        if serve and self.ppp is None:
            if ora < self.prossimo_tentativo:
                self.st["fase"] = "attesa nuovo tentativo"
            else:
                if self.sale(metrica):
                    self.cicli_falliti = 0
                else:
                    self.cicli_falliti += 1
                    self.st["ppp_riavvii"] += 1
                    if self.cicli_falliti >= 3 and self.cicli_falliti % 3 == 0:
                        self.reset_modulo()
                    self.prossimo_tentativo = time.time() + int(self.cfg["SIM_RETRY"])
                    self.st["fase"] = "tentativo fallito"
        elif self.ppp is not None:
            if not serve:
                self.ppp_ferma("il Wi-Fi funziona di nuovo")
            elif self.ppp.poll() is not None:
                evento("pppd e' terminato (codice %s)" % self.ppp.returncode)
                self.ppp_ferma("pppd terminato")
                self.cicli_falliti += 1
                self.st["ppp_riavvii"] += 1
                self.prossimo_tentativo = time.time() + 30
            elif ora - self.ultima_prova >= int(self.cfg["SIM_CHECK_EVERY"]):
                self.ultima_prova = ora
                if ping_su("ppp0", self.cfg["SIM_PING_HOST"], 20):
                    if self.prove_fallite:
                        evento("traffico di nuovo ok su ppp0")
                    self.prove_fallite = 0
                    self.st["ultimo_ping_ok"] = int(ora)
                else:
                    self.prove_fallite += 1
                    if self.prove_fallite >= int(self.cfg["SIM_FAIL_MAX"]):
                        evento("%d prove di traffico fallite: rilancio il PPP" % self.prove_fallite)
                        self.ppp_ferma("nessun traffico")
                        self.st["ppp_riavvii"] += 1
                        self.cicli_falliti += 1
                        self.prove_fallite = 0
                        self.prossimo_tentativo = time.time() + 15
            if self.ppp is not None:
                # DNS della SIM solo mentre il Wi-Fi non da' internet
                if not self.wifi:
                    self.dns_scrivi()
                else:
                    self.dns_ripristina()
                if self.ppp.poll() is None:
                    self.imposta_strada(700 if self.wifi else 50)
            self.conta_dati()
        elif not serve:
            self.st["fase"] = "SIM non serve (Wi-Fi ok)" if self.cfg["SIM_MODE"] == "auto" else "spento"
        self.scrivi_stato()

    def chiudi(self, *_):
        self.terminato = True

    def corri(self):
        signal.signal(signal.SIGTERM, self.chiudi)
        signal.signal(signal.SIGINT, self.chiudi)
        evento("servizio avviato (v%s, modo %s)" % (VERSIONE, self.cfg["SIM_MODE"]))
        while not self.terminato:
            try:
                self.giro()
            except Exception as e:      # il servizio non deve morire per un errore isolato
                evento("errore interno: %r" % (e,))
            fine = time.time() + TICK
            while time.time() < fine and not self.terminato:
                time.sleep(0.5)
        self.ppp_ferma("servizio fermato")
        self.scrivi_stato()
        evento("servizio fermato")


if __name__ == "__main__":
    if leggi_conf()["SIM_MODE"] == "off":
        print("SIM_MODE=off: niente da fare")
        sys.exit(0)
    Servizio().corri()
