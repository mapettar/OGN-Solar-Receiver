#!/bin/bash
# install.sh v1.8 - installa su Raspberry Pi 3A+ (Bookworm) tutto quello che e' nel repository:
#   ogn-boot-setup (ora DS3231 + spegnimento serale), calc_sunset, monitor_batteria,
#   stato (riepilogo mattutino), bme280_log, ds3231_log, cron e logrotate.
# v1.8: ogn-rtc-ora (ora del DS3231 nell'orologio di sistema all'avvio, prima della rete e prima di ogn-sim).
# v1.7: opzione --sim off|auto|always (+ --sim-apn): collegamento a internet via SIM7080G con PPP (ogn_sim.py, ogn-sim.service, /etc/default/ogn-sim, chat e peer di pppd).
# v1.6: opzione --hw-watchdog on|off: watchdog hardware del SoC (systemd lo alimenta; se la Pi si congela si riavvia da sola in ~15 s) e journal persistente.
# v1.5: opzione --watchdog off|prova|on: riavvio automatico se la chiavetta RTL-SDR manca (ogn-usb-watchdog.sh, cron ogni 5 min).
# v1.4: opzione --web on: pagina di stato sulla porta 8090 (stato_web.py + ogn-stato-web.service), solo rete locale/Tailscale.
# v1.3: cron per il secondo INA219 (0x41, carica) in /var/log/carica.csv; se non e' montato non scrive nulla.
#
# NON installa rtlsdr-ogn, NON configura Wi-Fi e NON tocca Tailscale (nessuna chiave qui).
# Prerequisito: Raspberry Pi OS Lite Bookworm con SSH attivo e rtlsdr-ogn gia' funzionante.
#
# Uso (da scaricare, leggere e poi lanciare):
#   curl -fsSLo install.sh "https://raw.githubusercontent.com/mapettar/OGN-Solar-Receiver/rpi-bookworm-3a-plus/src/rpi-bookworm/install.sh"
#   sudo bash install.sh --pacco 3s-liion --schedule on
#
# Opzioni:
#   --pacco 3s-liion|2s-lifepo4   profilo batteria per stato e monitor_batteria (default 3s-liion)
#   --schedule on|off             on = spegnimento serale al tramonto (con ATtiny e DS3231 collegati);
#                                 off = la Pi non si spegne da sola (default, sicuro per i banchi di prova)
#   --web on|off                  on = pagina di stato HTML sulla porta 8090, aggiornata ogni 10 minuti (default off)
#   --watchdog off|prova|on       riavvia la Pi se la chiavetta manca: prova = solo log, on = riavvia davvero (non cambia se omessa)
#   --hw-watchdog on|off          on = riavvio automatico se tutto il sistema si blocca (watchdog del chip, 15 s); off = lo toglie (non cambia se omessa)
#   --sim off|auto|always         SIM7080G con PPP: auto = solo se il Wi-Fi non da' internet, always = sempre su, off = spento (non cambia se omessa)
#   --sim-apn NOME                APN della SIM (default simbase)
#   --branch NOME                 ramo del repository (default rpi-bookworm-3a-plus)
#   --local CARTELLA              usa i file di una copia locale invece di scaricarli
#   --no-system                   non tocca apt, systemctl, timezone, config.txt (per i test)
# Si puo' rilanciare quante volte si vuole: i file diversi vengono salvati come .bak-AAAAMMGG-HHMM.
set -euo pipefail

BRANCH=rpi-bookworm-3a-plus
PACCO=3s-liion
SCHEDULE=off
WEB=off
WATCHDOG=""
HWWD=""
SIM=""
SIM_APN=simbase
LOCAL=""
NOSYSTEM=0
DESTDIR=${DESTDIR:-}
REPO=mapettar/OGN-Solar-Receiver

while [ $# -gt 0 ]; do
  case "$1" in
    --pacco)    PACCO=$2; shift 2;;
    --schedule) SCHEDULE=$2; shift 2;;
    --web)      WEB=$2; shift 2;;
    --watchdog) WATCHDOG=$2; shift 2;;
    --hw-watchdog) HWWD=$2; shift 2;;
    --sim)      SIM=$2; shift 2;;
    --sim-apn)  SIM_APN=$2; shift 2;;
    --branch)   BRANCH=$2; shift 2;;
    --local)    LOCAL=$2; shift 2;;
    --no-system) NOSYSTEM=1; shift;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0;;
    *) echo "Opzione sconosciuta: $1 (usa --help)"; exit 1;;
  esac
done
case "$PACCO" in 3s-liion|2s-lifepo4) ;; *) echo "--pacco: 3s-liion oppure 2s-lifepo4"; exit 1;; esac
case "$SCHEDULE" in on|off) ;; *) echo "--schedule: on oppure off"; exit 1;; esac
case "$WEB" in on|off) ;; *) echo "--web: on oppure off"; exit 1;; esac
case "$WATCHDOG" in ""|off|prova|on) ;; *) echo "--watchdog: off, prova oppure on"; exit 1;; esac
case "$HWWD" in ""|on|off) ;; *) echo "--hw-watchdog: on oppure off"; exit 1;; esac
case "$SIM" in ""|off|auto|always) ;; *) echo "--sim: off, auto oppure always"; exit 1;; esac
case "$SIM_APN" in *[!A-Za-z0-9._-]*|"") echo "--sim-apn: solo lettere, numeri, punto, trattino"; exit 1;; esac

BASE="https://raw.githubusercontent.com/$REPO/$BRANCH/src/rpi-bookworm"
STAMP=$(date +%Y%m%d-%H%M)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say()  { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   [!!] %s\n' "$*"; }

[ "$NOSYSTEM" -eq 1 ] || [ "$(id -u)" -eq 0 ] || { echo "Lancia con sudo: sudo bash $0 $*"; exit 1; }

# --- 0. Controlli sul sistema ----------------------------------------------
say "Controlli"
if [ "$NOSYSTEM" -eq 0 ]; then
  . /etc/os-release
  [ "${VERSION_CODENAME:-}" = "bookworm" ] && info "Raspberry Pi OS Bookworm: ok" \
    || warn "il sistema e' '${VERSION_CODENAME:-?}', non Bookworm: gli script sono provati solo su Bookworm"
  BIT=$(getconf LONG_BIT)
  [ "$BIT" = "32" ] && info "sistema a 32 bit: ok per rtlsdr-ogn 0.3.3" \
    || warn "sistema a $BIT bit: rtlsdr-ogn 0.3.3 richiede 32 bit (la stazione MCucco funziona con un artificio, vedi la guida)"
  UF=$(systemctl list-unit-files 2>/dev/null || true)
  case "$UF" in
    *rtlsdr-ogn*) info "servizio rtlsdr-ogn presente";;
    *) warn "servizio rtlsdr-ogn NON trovato: installa prima OGN (questo script non lo fa)";;
  esac
fi

# --- 1. Pacchetti -----------------------------------------------------------
if [ "$NOSYSTEM" -eq 0 ]; then
  say "Pacchetti"
  NEED=""
  command -v i2cget   >/dev/null 2>&1 || NEED="$NEED i2c-tools"
  command -v crontab  >/dev/null 2>&1 || NEED="$NEED cron"
  command -v python3  >/dev/null 2>&1 || NEED="$NEED python3"
  command -v lsusb    >/dev/null 2>&1 || NEED="$NEED usbutils"       # lo usa "stato" per la chiavetta RTL-SDR
  if [ -n "$SIM" ] && [ "$SIM" != off ]; then
    command -v pppd >/dev/null 2>&1 || NEED="$NEED ppp"
    python3 -c "import serial" >/dev/null 2>&1 || NEED="$NEED python3-serial"
  fi
  if [ -n "$NEED" ]; then info "installo:$NEED"; apt-get update -qq; apt-get install -y -qq --no-install-recommends $NEED; else info "nessun pacchetto da installare"; fi

  say "I2C"
  CFG=/boot/firmware/config.txt; [ -f "$CFG" ] || CFG=/boot/config.txt
  if grep -qE '^dtparam=i2c_arm=on' "$CFG"; then info "I2C gia' attivo in $CFG"
  else printf '\ndtparam=i2c_arm=on\n' >> "$CFG"; info "attivato I2C in $CFG (serve un riavvio)"; fi
  grep -qE '^dtoverlay=i2c-rtc' "$CFG" && warn "dtoverlay=i2c-rtc attivo in $CFG: va commentato, e' in conflitto con l'ATtiny"
  grep -qx 'i2c-dev' /etc/modules-load.d/i2c.conf 2>/dev/null || { mkdir -p /etc/modules-load.d; echo i2c-dev >> /etc/modules-load.d/i2c.conf; }
  timedatectl set-timezone Europe/Rome && info "fuso orario: Europe/Rome"
fi

# --- 2. File ----------------------------------------------------------------
say "File"
fetch() {   # fetch <nome nel repository> <destinazione> <modo>
  local nome=$1 dest="$DESTDIR$2" modo=$3 src="$TMP/$1"
  if [ -n "$LOCAL" ]; then cp "$LOCAL/$nome" "$src"
  else curl -fsSL "$BASE/$nome?v=$(date +%s)" -o "$src"; fi
  [ -s "$src" ] || { echo "ERRORE: $nome vuoto o non scaricato"; exit 1; }
  case "$nome" in
    *.sh) bash -n "$src" || { echo "ERRORE: $nome non e' uno script valido"; exit 1; };;
    *.py) python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$src" || { echo "ERRORE: $nome non e' valido"; exit 1; };;
  esac
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then cp -p "$dest" "$dest.bak-$STAMP"; info "copia di sicurezza: $dest.bak-$STAMP"; fi
  install -m "$modo" "$src" "$dest"
  info "$dest"
}
fetch ogn-boot-setup.sh       /usr/local/sbin/ogn-boot-setup.sh   755
fetch calc_sunset.py          /usr/local/sbin/calc_sunset.py      755
fetch monitor_batteria.py     /usr/local/sbin/monitor_batteria.py 755
fetch stato_stazione.sh       /usr/local/sbin/stato_stazione.sh   755
fetch bme280_log.py           /usr/local/sbin/bme280_log.py       755
fetch ds3231_log.sh           /usr/local/sbin/ds3231_log.sh       755
fetch ogn-boot-setup.service  /etc/systemd/system/ogn-boot-setup.service 644
fetch ogn-rtc-ora.sh          /usr/local/sbin/ogn-rtc-ora.sh      755
fetch ogn-rtc-ora.service     /etc/systemd/system/ogn-rtc-ora.service 644
if [ -n "$WATCHDOG" ] && [ "$WATCHDOG" != off ]; then
  fetch ogn-usb-watchdog.sh     /usr/local/sbin/ogn-usb-watchdog.sh 755
fi
if [ -n "$SIM" ] && [ "$SIM" != off ]; then
  fetch ogn_sim.py              /usr/local/sbin/ogn_sim.py          755
  fetch ogn-sim.service         /etc/systemd/system/ogn-sim.service 644
fi
if [ "$WEB" = on ]; then
  fetch stato_web.py            /usr/local/sbin/stato_web.py        755
  fetch ogn-stato-web.service   /etc/systemd/system/ogn-stato-web.service 644
fi

# Comando corto "stato"
mkdir -p "$DESTDIR/usr/local/bin"
printf '#!/bin/bash\nexec sudo bash /usr/local/sbin/stato_stazione.sh "$@"\n' > "$DESTDIR/usr/local/bin/stato"
chmod 755 "$DESTDIR/usr/local/bin/stato"; info "$DESTDIR/usr/local/bin/stato"

# Impostazioni (non si sovrascrivono se esistono gia')
mkdir -p "$DESTDIR/etc/default"
DEF="$DESTDIR/etc/default/ogn-boot-setup"
if [ -f "$DEF" ]; then
  info "$DEF esiste gia', lo lascio com'e':"; sed 's/^/      /' "$DEF"
  grep -q '^OGN_PACCO=' "$DEF" || echo "OGN_PACCO=$PACCO" >> "$DEF"
else
  printf 'SCHEDULE=%s\nOGN_PACCO=%s\n' "$SCHEDULE" "$PACCO" > "$DEF"; info "creato $DEF (SCHEDULE=$SCHEDULE, OGN_PACCO=$PACCO)"
fi
if [ -n "$WATCHDOG" ]; then
  sed -i '/^WATCHDOG_USB=/d' "$DEF"; echo "WATCHDOG_USB=$WATCHDOG" >> "$DEF"; info "WATCHDOG_USB=$WATCHDOG in $DEF"
fi

# Journal persistente (serve a capire dopo un blocco cosa e' successo) e watchdog hardware
say "Journal e watchdog hardware"
mkdir -p "$DESTDIR/etc/systemd/journald.conf.d"
printf '[Journal]\nStorage=persistent\nSystemMaxUse=50M\n' > "$DESTDIR/etc/systemd/journald.conf.d/ogn-persistent.conf"
mkdir -p "$DESTDIR/var/log/journal"
info "journal persistente (max 50 MB): $DESTDIR/etc/systemd/journald.conf.d/ogn-persistent.conf"
WDF="$DESTDIR/etc/systemd/system.conf.d/ogn-watchdog.conf"
case "$HWWD" in
  on)
    mkdir -p "$(dirname "$WDF")"
    printf '[Manager]\nRuntimeWatchdogSec=15\nRebootWatchdogSec=2min\n' > "$WDF"
    info "watchdog hardware attivo (15 s): $WDF"
    [ "$NOSYSTEM" -eq 1 ] || [ -e /dev/watchdog ] || warn "/dev/watchdog non trovato: il driver del chip non e' caricato, il watchdog non funzionera'";;
  off)
    rm -f "$WDF"; info "watchdog hardware tolto";;
  *)
    [ -f "$WDF" ] && info "watchdog hardware: gia' configurato, lo lascio com'e'" || info "watchdog hardware: non attivo (usa --hw-watchdog on)";;
esac

# SIM7080G: impostazioni, chat e peer di pppd (dispositivo e velocita' li passa ogn_sim.py)
if [ -n "$SIM" ]; then
  SIMDEF="$DESTDIR/etc/default/ogn-sim"
  if [ ! -f "$SIMDEF" ]; then
    cat > "$SIMDEF" <<SIMEOF
# Impostazioni del collegamento SIM (ogn_sim.py). Modi: off | auto | always
SIM_MODE=$SIM
SIM_APN=$SIM_APN
# Altre voci (valori predefiniti): SIM_RAT=ltem SIM_BAUD=57600 SIM_PWR_PIN=4 SIM_PWR_ACTIVE=high
#   SIM_PLMN=22210 (Vodafone IT, consigliato con la SIM Simbase) SIM_WIFI_GRACE=90 SIM_WIFI_BACK=300 SIM_DNS="1.1.1.1 8.8.8.8" SIM_DNS_MODE=write|none
SIMEOF
    info "creato $SIMDEF (SIM_MODE=$SIM, APN $SIM_APN)"
  else
    sed -i '/^SIM_MODE=/d' "$SIMDEF"; echo "SIM_MODE=$SIM" >> "$SIMDEF"
    if [ "$SIM_APN" != simbase ]; then sed -i '/^SIM_APN=/d' "$SIMDEF"; echo "SIM_APN=$SIM_APN" >> "$SIMDEF"; fi
    info "$SIMDEF aggiornato: SIM_MODE=$SIM"
  fi
  APN_LETTO=$(grep '^SIM_APN=' "$SIMDEF" | tail -1 | cut -d= -f2)
  APN_LETTO=${APN_LETTO:-$SIM_APN}
  mkdir -p "$DESTDIR/etc/ppp/peers"
  {
    echo 'ABORT "NO CARRIER"'
    echo 'ABORT "ERROR"'
    echo 'ABORT "NO DIALTONE"'
    echo 'ABORT "BUSY"'
    echo 'TIMEOUT 40'
    echo '"" "AT"'
    echo "OK \"AT+CGDCONT=1,\\\"IP\\\",\\\"$APN_LETTO\\\"\""
    echo 'OK "ATD*99#"'
    echo 'CONNECT ""'
  } > "$DESTDIR/etc/ppp/chat-simbase"
  cat > "$DESTDIR/etc/ppp/peers/simbase" <<'SIMEOF'
# Creato da install.sh. Dispositivo e velocita' li passa ogn_sim.py sulla riga di comando.
connect "/usr/sbin/chat -v -f /etc/ppp/chat-simbase"
noauth
local
lock
nocrtscts
noipdefault
noccp
noipv6
holdoff 10
lcp-echo-interval 60
lcp-echo-failure 5
SIMEOF
  info "$DESTDIR/etc/ppp/chat-simbase e peers/simbase"
fi

# Cron e rotazione dei log
mkdir -p "$DESTDIR/etc/cron.d" "$DESTDIR/etc/logrotate.d"
cat > "$DESTDIR/etc/cron.d/ogn-station" <<EOF
# Creato da install.sh: log DS3231 (1 min), BME280 (5 min), batteria INA219 0x40 (10 min), carica INA219 0x41 (10 min, se montato)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * *    root /usr/local/sbin/ds3231_log.sh
*/5 * * * *  root /usr/bin/python3 /usr/local/sbin/bme280_log.py >/dev/null 2>&1
*/10 * * * * root /usr/bin/python3 /usr/local/sbin/monitor_batteria.py --pacco $PACCO --csv >> /var/log/batteria.csv 2>/dev/null
*/10 * * * * root /usr/bin/python3 /usr/local/sbin/monitor_batteria.py --addr 0x41 --carica --csv >> /var/log/carica.csv 2>/dev/null
EOF
[ -n "$WATCHDOG" ] && [ "$WATCHDOG" != off ] && echo '*/5 * * * * root /usr/local/sbin/ogn-usb-watchdog.sh' >> "$DESTDIR/etc/cron.d/ogn-station"
[ "$WEB" = on ] && echo '*/10 * * * * root nice -n 10 /usr/bin/python3 /usr/local/sbin/stato_web.py >/dev/null 2>&1' >> "$DESTDIR/etc/cron.d/ogn-station"
chmod 644 "$DESTDIR/etc/cron.d/ogn-station"; info "$DESTDIR/etc/cron.d/ogn-station"
cat > "$DESTDIR/etc/logrotate.d/ogn-station" <<'EOF'
/var/log/ds3231.log /var/log/batteria.csv /var/log/carica.csv /var/log/ogn-boot-setup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
info "$DESTDIR/etc/logrotate.d/ogn-station"

# --- 3. Servizio ------------------------------------------------------------
if [ "$NOSYSTEM" -eq 0 ]; then
  say "Servizio"
  systemctl daemon-reload
  systemctl restart systemd-journald && info "journal persistente attivo"
  systemctl daemon-reexec && info "systemd riletto (il watchdog hardware, se attivo, parte subito)"
  systemctl enable ogn-boot-setup.service
  info "ogn-boot-setup abilitato (parte ad ogni avvio)"
  systemctl enable ogn-rtc-ora.service
  info "ogn-rtc-ora abilitato (ora dal DS3231 all'avvio, prima della rete)"
  if [ -n "$SIM" ]; then
    if [ "$SIM" = off ]; then
      systemctl disable --now ogn-sim.service 2>/dev/null && info "servizio SIM spento"
    else
      systemctl enable ogn-sim.service && systemctl restart ogn-sim.service && info "servizio SIM attivo (modo $SIM)"
      info "SIM: serve il ponticello PWR-P7 sulla HAT e i pin 1-10 del connettore saldati"
    fi
  fi
  if [ "$WEB" = on ]; then
    mkdir -p /var/lib/ogn-stato
    /usr/bin/python3 /usr/local/sbin/stato_web.py || warn "prima generazione della pagina fallita (ci riprova il cron)"
    systemctl enable --now ogn-stato-web.service && info "pagina di stato: http://$(hostname -I | awk '{print $1}'):8090/ (rete locale e Tailscale; NON aprire la porta sul router)"
  fi
fi

say "Fatto"
info "pacco: $PACCO - spegnimento serale: $(grep '^SCHEDULE=' "$DEF" | cut -d= -f2)"
info "1) Riavvia la Pi:  sudo reboot"
info "2) Dopo 3-4 minuti:  stato"
info "3) Tailscale e il nome del ricevitore (riga  Call = \"NOME\";  nel Template.conf di rtlsdr-ogn, di solito ~/rtlsdr-ogn/rtlsdr-ogn-0.3.3/Template.conf) restano da fare a mano, con le tue chiavi."
[ "$(grep '^SCHEDULE=' "$DEF" | cut -d= -f2)" = "off" ] && info "Spegnimento serale OFF: per attivarlo, con ATtiny e DS3231 collegati:  echo SCHEDULE=on | sudo tee /etc/default/ogn-boot-setup"
exit 0
