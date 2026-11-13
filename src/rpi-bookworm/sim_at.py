#!/usr/bin/env python3
# sim_at.py - manda comandi AT al modulo SIM7080G (a servizio fermo: sudo systemctl stop ogn-sim).
# Uso:  sudo python3 sim_at.py                      -> diagnosi standard
#       sudo python3 sim_at.py "AT+CFUN=0" "AT+CFUN=1" "AT+CSQ"
#       sudo python3 sim_at.py --segnale [N]      -> N letture (predefinito 12, una ogni 5 s) e media di RSRP/RSRQ/RSSNR:
#                                                    serve a confrontare due antenne o due posizioni
import sys
sys.path.insert(0, "/usr/local/sbin")
import ogn_sim as o

DIAGNOSI = ["AT+CPIN?", "AT+CFUN?", "AT+CSQ", "AT+CEREG?", "AT+CPSI?", "AT+COPS?", "AT+CNMP?", "AT+CMNB?", "AT+CBANDCFG?"]

cfg = o.leggi_conf()
m = o.Modem(o.DEV)
b = o.trova_modulo(m, cfg)
if not b:
    print("il modulo non risponde ad AT")
    sys.exit(1)
print("modulo risponde a %d baud" % b)
if len(sys.argv) > 1 and sys.argv[1] == "--segnale":
    import re, time
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    rsrp, rsrq, snr, csq = [], [], [], []
    for i in range(n):
        info = o.interpreta_cpsi(m.at("AT+CPSI?", 5.0)[1])
        t = m.at("AT+CSQ", 3.0)[1]
        mm = re.search(r"\+CSQ:\s*(\d+)", t)
        if "rsrp" in info:
            rsrp.append(info["rsrp"])
            rsrq.append(info["rsrq"])
            print("%2d/%d  %s %s  RSRP %d  RSRQ %d  CSQ %s" % (i + 1, n, info.get("tecnologia", ""),
                  info.get("banda", ""), info["rsrp"], info["rsrq"], mm.group(1) if mm else "?"))
        else:
            print("%2d/%d  nessun servizio" % (i + 1, n))
        time.sleep(5)
    if rsrp:
        print("MEDIA su %d letture: RSRP %.1f dBm (da %d a %d), RSRQ %.1f" % (len(rsrp), sum(rsrp) / len(rsrp), min(rsrp), max(rsrp), sum(rsrq) / len(rsrq)))
    else:
        print("nessuna lettura valida")
    m.chiudi()
    sys.exit(0)
for c in (sys.argv[1:] or DIAGNOSI):
    ok, t = m.at(c, 15.0)
    print(">>", c)
    print(t)
m.chiudi()
