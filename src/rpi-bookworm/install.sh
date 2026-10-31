#!/bin/bash
# install.sh v1.3 - installa su Raspberry Pi 3A+ (Bookworm) tutto quello che e' nel repository:
#   ogn-boot-setup (ora DS3231 + spegnimento serale), calc_sunset, monitor_batteria,
#   stato (riepilogo mattutino), bme280_log, ds3231_log, cron e logrotate.
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
#   --branch NOME                 ramo del repository (default rpi-bookworm-3a-plus)
#   --local CARTELLA              usa i file di una copia locale invece di scaricarli
#   --no-system                   non tocca apt, systemctl, timezone, config.txt (per i test)
# Si puo' rilanciare quante volte si vuole: i file diversi vengono salvati come .bak-AAAAMMGG-HHMM.
set -euo pipefail

BRANCH=rpi-bookworm-3a-plus
PACCO=3s-liion
SCHEDULE=off
LOCAL=""
NOSYSTEM=0
DESTDIR=${DESTDIR:-}
REPO=mapettar/OGN-Solar-Receiver

while [ $# -gt 0 ]; do
  case "$1" in
    --pacco)    PACCO=$2; shift 2;;
    --schedule) SCHEDULE=$2; shift 2;;
    --branch)   BRANCH=$2; shift 2;;
    --local)    LOCAL=$2; shift 2;;
    --no-system) NOSYSTEM=1; shift;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0;;
    *) echo "Opzione sconosciuta: $1 (usa --help)"; exit 1;;
  esac
done
case "$PACCO" in 3s-liion|2s-lifepo4) ;; *) echo "--pacco: 3s-liion oppure 2s-lifepo4"; exit 1;; esac
case "$SCHEDULE" in on|off) ;; *) echo "--schedule: on oppure off"; exit 1;; esac

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
  systemctl enable ogn-boot-setup.service
  info "ogn-boot-setup abilitato (parte ad ogni avvio)"
fi

say "Fatto"
info "pacco: $PACCO - spegnimento serale: $(grep '^SCHEDULE=' "$DEF" | cut -d= -f2)"
info "1) Riavvia la Pi:  sudo reboot"
info "2) Dopo 3-4 minuti:  stato"
info "3) Tailscale e il nome del ricevitore (riga  Call = \"NOME\";  nel Template.conf di rtlsdr-ogn, di solito ~/rtlsdr-ogn/rtlsdr-ogn-0.3.3/Template.conf) restano da fare a mano, con le tue chiavi."
[ "$(grep '^SCHEDULE=' "$DEF" | cut -d= -f2)" = "off" ] && info "Spegnimento serale OFF: per attivarlo, con ATtiny e DS3231 collegati:  echo SCHEDULE=on | sudo tee /etc/default/ogn-boot-setup"
exit 0
