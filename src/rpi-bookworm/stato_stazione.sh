#!/bin/bash
# stato_stazione.sh v1.5 - riepilogo mattutino della stazione OGN (Pi 3A+ Bookworm)
# Uso:  stato   (oppure: sudo bash /usr/local/sbin/stato_stazione.sh)
# Controlla avvio, orologio DS3231, ciclo spegnimento/avvio, servizi OGN, chiavetta RTL-SDR
# e collegamento al server APRS, alimentazione, batteria (se l'INA219 e' collegato),
# scatola (BME280) e disco. In fondo il verdetto.
# Non modifica niente: legge soltanto.
# v1.4: aggiunta la sezione "Ricevitore": il solo processo ogn-rf in esecuzione NON prova che
#       riceva (31 ott 2026: chiavetta non rilevata dall'avvio, ogn-rf in attesa, "TUTTO OK").
# v1.5: dalla prova reale con chiavetta scollegata e ricollegata:
#       - i tentativi falliti di ogn-rf distinguono "in corso" da "episodio concluso" (ora dell'ultimo);
#       - CPU di ogn-rf misurata sul momento (1 s) e non come media dall'avvio;
#       - il collegamento APRS dice solo che la rete e il server rispondono, non che si riceve;
#       - una prima lettura fallita del DS3231 non conta piu' come "ora presente".

PROBLEMI=0
# Impostazioni della stazione (profilo pacco, SCHEDULE): create da install.sh
[ -f /etc/default/ogn-boot-setup ] && . /etc/default/ogn-boot-setup
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; PROBLEMI=$((PROBLEMI + 1)); }
info() { printf '       %s\n' "$*"; }
titolo() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Lanciare con sudo: sudo bash $0"; exit 1; }

OGGI=$(date +%F)
IERI=$(date -d yesterday +%F)
EVENTI=${EVENTI:-/boot/ogn-eventi.log}
DSLOG=${DSLOG:-/boot/ds3231.log}; [ -f "$DSLOG" ] || DSLOG=/var/log/ds3231.log
BMELOG=${BMELOG:-/boot/bme280.log}

echo "STATO STAZIONE $(hostname) - $(date '+%F %T') (UTC $(date -u +%H:%M:%S))"

# --- 1. Avvio --------------------------------------------------------------
titolo "Avvio"
AVVIO=$(uptime -s)
AVVIO_LOC=${AVVIO:11:5}
SEC=$(cut -d. -f1 /proc/uptime)
AVVIO_UTC=$(date -u -d "@$(( $(date +%s) - SEC ))" +%H:%M)
info "acceso dalle ${AVVIO:11:8} locali (${AVVIO_UTC} UTC), in funzione da $((SEC/3600)) h $(((SEC%3600)/60)) min"
# atteso: 10:00 locali (script nuovi) oppure 08:00 UTC (script vecchi); tolleranza 10 minuti
if [[ "$AVVIO_LOC" > "09:59" && "$AVVIO_LOC" < "10:11" ]]; then
  ok "partita alle 10:00 locali"
elif [[ "$AVVIO_UTC" > "07:59" && "$AVVIO_UTC" < "08:11" ]]; then
  ok "partita alle 08:00 UTC (sistema con script UTC)"
else
  warn "avvio fuori orario (atteso 10:00 locali o 08:00 UTC): riavvio manuale o ATtiny in recupero?"
fi

# --- 2. Orologio DS3231 ----------------------------------------------------
titolo "Orologio DS3231"
if command -v i2cget >/dev/null 2>&1; then
  modprobe i2c-dev 2>/dev/null
  S=$(i2cget -y 1 0x68 0x00 2>/dev/null); M=$(i2cget -y 1 0x68 0x01 2>/dev/null)
  H=$(i2cget -y 1 0x68 0x02 2>/dev/null); ST=$(i2cget -y 1 0x68 0x0f 2>/dev/null)
  if [ -n "$S" ] && [ -n "$M" ] && [ -n "$H" ] && [ -n "$ST" ]; then
    bcd() { local v=$(( $1 )); echo $(( (v >> 4) * 10 + (v & 15) )); }
    DS=$(( $(bcd $(( H & 0x3F )))*3600 + $(bcd $M)*60 + $(bcd $S) ))
    NOW=$(date -u +%s); NOW=$(( NOW % 86400 ))
    D=$(( DS - NOW )); [ $D -gt 43200 ] && D=$(( D - 86400 )); [ $D -lt -43200 ] && D=$(( D + 86400 ))
    info "DS3231 $(printf '%02d:%02d:%02d' $(bcd $(( H & 0x3F ))) $(bcd $M) $(bcd $S)), stato $ST, differenza dall'ora UTC: ${D}s"
    if [ $(( ST & 0x80 )) -ne 0 ]; then warn "OSF acceso: il DS3231 ha perso l'ora (riscritta all'avvio?)"; else ok "OSF spento"; fi
    AD=${D#-}; AD2=$(( D + 3600 )); AD2=${AD2#-}
    if [ "$AD" -le 3 ] || [ "$AD2" -le 3 ]; then
      ok "ora allineata (0 s con script UTC, -3600 s con script ora locale)"
    else
      warn "ora non allineata (differenza ${D}s)"
    fi
  else
    warn "DS3231 non risponde su 0x68"
  fi
else
  warn "i2cget non installato"
fi
if [ -f "$DSLOG" ]; then
  PRIMA=$(grep -a "^$OGGI" "$DSLOG" | head -1)
  info "prima lettura di oggi: ${PRIMA:-nessuna}"
  case "$PRIMA" in *"st=0x8"*) warn "alla prima lettura del giorno OSF acceso: l'ora si era persa durante la notte";;
                   *"Read failed"*) info "la prima lettura del giorno e' fallita: non si puo' dire se l'ora era presente";;
                   "") : ;; *) ok "alla prima lettura del giorno l'ora era presente";; esac
  N_OSF=$(grep -a "^$OGGI" "$DSLOG" | grep -ac "st=0x[89a-f]")
  N_ERR=$(grep -a "^$OGGI" "$DSLOG" | grep -ac "Read failed")
  info "righe di oggi con OSF acceso: $N_OSF  -  letture I2C fallite: $N_ERR"
  [ "$N_ERR" -gt 0 ] && warn "$N_ERR letture I2C fallite oggi"
else
  info "nessun log del DS3231 trovato"
fi
if command -v ntpq >/dev/null 2>&1 && ntpq -pn 2>/dev/null | grep -q '^\*'; then ok "NTP sincronizzato"
elif [ -e /run/systemd/timesync/synchronized ]; then ok "NTP sincronizzato (timesyncd)"
else warn "NTP non sincronizzato"; fi

# --- 3. Ciclo accensione/spegnimento ---------------------------------------
titolo "Ciclo spegnimento / avvio"
if [ -f "$EVENTI" ]; then
  tail -n 6 "$EVENTI" | sed 's/^/       /'
  if grep -a "^$IERI" "$EVENTI" | grep -aq shutdown; then ok "spegnimento di ieri sera registrato"
  else warn "nessuno spegnimento registrato ieri ($IERI): taglio brusco dell'ATtiny?"; fi
  if grep -a "^$OGGI" "$EVENTI" | grep -aq avvio; then ok "avvio di oggi registrato"
  else warn "nessun avvio registrato oggi"; fi
  grep -a "^$OGGI" "$EVENTI" | grep -aq "NTP_OK=0" && warn "avvio con NTP_OK=0 (DS3231 non riscritto)"
else
  warn "file $EVENTI non trovato"
fi

# --- 4. Servizi OGN --------------------------------------------------------
titolo "Servizi OGN"
for p in ogn-rf ogn-decode; do
  if pgrep -f "$p" >/dev/null 2>&1; then ok "$p in esecuzione"; else warn "$p NON in esecuzione"; fi
done

# --- 4b. Ricevitore: chiavetta RTL-SDR e collegamento al server ------------
titolo "Ricevitore (chiavetta e server OGN)"
UNITA_RF=${UNITA_RF:-rtlsdr-ogn}
if command -v lsusb >/dev/null 2>&1; then
  SDR=$(lsusb 2>/dev/null | grep -iE 'ID 0bda:28(32|38)' | head -1)
  if [ -n "$SDR" ]; then ok "chiavetta RTL-SDR presente: ${SDR#*ID }"
  else warn "chiavetta RTL-SDR NON rilevata da lsusb: ogn-rf non puo' ricevere"; fi
else
  info "lsusb non installato (pacchetto usbutils)"
fi
N_USB=$(dmesg 2>/dev/null | grep -aciE 'usb [0-9.-]+: (device descriptor read.*error -71|device not accepting address)|disabled by hub')
if [ "${N_USB:-0}" -gt 0 ]; then
  warn "errori USB nel log del kernel dall'avvio: $N_USB righe (contatto, cavo o alimentazione della porta?)"
else
  ok "nessun errore USB nel log del kernel"
fi
# Tentativi falliti di ogn-rf ("Cannot open device"): in corso, concluso o solo all'avvio
if command -v journalctl >/dev/null 2>&1; then
  FALLITI=$(journalctl -b -u "$UNITA_RF" -o short-unix --no-pager 2>/dev/null | grep -a 'Cannot open device')
  N_APRI=$(printf '%s' "$FALLITI" | grep -ac 'Cannot open device')
  ULT=$(printf '%s\n' "$FALLITI" | tail -1 | cut -d. -f1)
  if [ "${N_APRI:-0}" -eq 0 ] || ! [ "${ULT:-x}" -eq "${ULT:-x}" ] 2>/dev/null; then
    ok "ogn-rf apre la chiavetta senza errori"
  else
    QUANDO=$(date -d "@$ULT" +%H:%M:%S 2>/dev/null)
    if [ $(( $(date +%s) - ULT )) -lt 90 ]; then
      warn "ogn-rf NON riesce ad aprire la chiavetta: ultimo tentativo fallito alle $QUANDO ($N_APRI dall'avvio)"
    elif [ "$N_APRI" -ge 6 ]; then
      warn "episodio concluso: ogn-rf ha avuto $N_APRI tentativi falliti dall'avvio, l'ultimo alle $QUANDO (ora la chiavetta si apre)"
    else
      info "ogn-rf: $N_APRI tentativi falliti dall'avvio (ultimo alle $QUANDO): normale all'accensione"
    fi
  fi
fi
# CPU di ogn-rf sul momento (1 s): varia (40-110% sulla Zero 2W); avviso solo sotto il 15%
cpu_istantanea() {
  local pid=$1 t1 t2 hz
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  t1=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null) || return 1
  sleep 1
  t2=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null) || return 1
  echo $(( (t2 - t1) * 100 / hz ))
}
RFPID=$(pgrep -x ogn-rf 2>/dev/null | head -1)
if [ -n "$RFPID" ]; then
  RFCPU=$(cpu_istantanea "$RFPID")
  info "CPU di ogn-rf sul momento: ${RFCPU:-n/d}% (misurata sulla Zero 2W: da 40% a oltre 100% quando lavora; sotto 15% e' sospetto)"
  if [ -n "${SDR:-}" ] && [ "$SEC" -ge 300 ] && [ -n "$RFCPU" ] && [ "$RFCPU" -lt 15 ]; then
    warn "ogn-rf quasi inattivo con la chiavetta presente ($RFCPU%): controllare $UNITA_RF"
  fi
else
  info "processo ogn-rf non trovato"
fi
if ss -tn 2>/dev/null | grep -E ':(14580|10152)( |$)' | grep -q ESTAB; then
  ok "rete: collegamento al server APRS stabilito (non prova che si riceva)"
else
  warn "nessun collegamento al server APRS (porta 14580): rete o server non raggiungibili"
fi

# --- 5. Alimentazione e temperatura ----------------------------------------
titolo "Alimentazione e temperatura"
if command -v vcgencmd >/dev/null 2>&1; then
  T=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
  if [ "$T" = "0x0" ]; then ok "nessun sottovoltaggio o limitazione dall'avvio"
  else
    V=$(( T ))
    [ $(( V & 0x1 )) -ne 0 ] && warn "sottovoltaggio IN CORSO"
    [ $(( V & 0x4 )) -ne 0 ] && warn "CPU limitata IN CORSO"
    [ $(( V & 0x10000 )) -ne 0 ] && warn "c'e' stato sottovoltaggio dall'avvio ($T)"
    [ $(( V & 0x40000 )) -ne 0 ] && warn "c'e' stata limitazione della CPU dall'avvio ($T)"
    [ $(( V & 0x80000 )) -ne 0 ] && warn "limite termico raggiunto dall'avvio ($T)"
  fi
  info "CPU: $(vcgencmd measure_temp 2>/dev/null)"
fi

# --- 6. Batteria (INA219) --------------------------------------------------
titolo "Batteria"
MB=""
for f in /usr/local/sbin/monitor_batteria.py /boot/monitor_batteria.py /boot/firmware/monitor_batteria.py /home/pi/monitor_batteria.py; do
  [ -f "$f" ] && { MB=$f; break; }
done
if [ -n "$MB" ]; then
  OUT=$(timeout 10 python3 "$MB" --pacco "${OGN_PACCO:-3s-liion}" 2>&1)
  if echo "$OUT" | grep -q Traceback; then
    info "INA219 non risponde (non collegato?): $(echo "$OUT" | tail -1)"
    OUT=""
  else
    OUT=$(echo "$OUT" | head -5)
    echo "$OUT" | sed 's/^/       /'
  fi
  VB=$(echo "$OUT" | awk '/Tensione/{print $2}')
  if [ -z "$OUT" ]; then :
  elif [ -n "$VB" ] && awk -v v="$VB" 'BEGIN{exit !(v < 3.0)}'; then
    info "tensione sotto 3 V: INA219 senza batteria collegata (stazione di prova), lettura ignorata"
  elif echo "$OUT" | grep -qiE "critic|bassa|errore"; then
    warn "controllare la batteria"
  fi
else
  info "monitor_batteria.py non trovato"
fi

# --- 7. Scatola (BME280) ---------------------------------------------------
titolo "Scatola (BME280)"
if [ -f "$BMELOG" ] && grep -aq "^$OGGI" "$BMELOG"; then
  grep -a "^$OGGI" "$BMELOG" | head -1 | sed 's/^/       prima lettura: /'
  grep -a "^$OGGI" "$BMELOG" | tail -1 | sed 's/^/       ultima lettura: /'
  RIS=$(grep -a "^$OGGI" "$BMELOG" | awk -F'[ =]' '$6 ~ /^[0-9.]+$/ {
      m = $4 - $10; if (n == 0 || m < mm) mm = m; if (n == 0 || $6 > rm) rm = $6; n++ }
    END { if (n) printf "%.1f %.1f", mm, rm }')
  if [ -n "$RIS" ]; then
    MARG=${RIS% *}; RHMAX=${RIS#* }
    info "oggi: margine minimo dal punto di rugiada ${MARG} C, umidita massima ${RHMAX}%"
    if awk -v m="$MARG" 'BEGIN{exit !(m < 3)}'; then warn "margine sotto 3 C: rischio condensa"; fi
    if awk -v r="$RHMAX" 'BEGIN{exit !(r >= 80)}'; then warn "umidita' >= 80%"; fi
  fi
  grep -a "^$OGGI" "$EVENTI" 2>/dev/null | grep -a ALERT | sed 's/^/       /'
else
  info "nessuna lettura BME280 oggi (sensore assente o cron non attivo)"
fi

# --- 8. Disco --------------------------------------------------------------
titolo "Disco"
FS=$(findmnt -n -o FSTYPE / 2>/dev/null)
info "root: $FS, uso $(df -h / | awk 'NR==2{print $5" di "$2}'), /boot: $(df -h /boot | awk 'NR==2{print $5" di "$2}')"
USO=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
[ "${USO:-0}" -ge 90 ] && warn "disco quasi pieno"

# --- Verdetto --------------------------------------------------------------
titolo "Verdetto"
if [ "$PROBLEMI" -eq 0 ]; then echo "  TUTTO OK"; else echo "  ATTENZIONE: $PROBLEMI voci da controllare (righe [!!])"; fi
