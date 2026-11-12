#!/usr/bin/env python3
# sim_at.py - manda comandi AT al modulo SIM7080G (a servizio fermo: sudo systemctl stop ogn-sim).
# Uso:  sudo python3 sim_at.py                      -> diagnosi standard
#       sudo python3 sim_at.py "AT+CFUN=0" "AT+CFUN=1" "AT+CSQ"
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
for c in (sys.argv[1:] or DIAGNOSI):
    ok, t = m.at(c, 15.0)
    print(">>", c)
    print(t)
m.chiudi()
