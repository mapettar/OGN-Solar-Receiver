#!/bin/bash
# ogn-usb-watchdog.sh v1.1 - riavvia la Pi se la chiavetta RTL-SDR manca o ogn-rf non riesce ad aprirla.
# Si lancia da cron ogni 5 minuti (come root). Il 31 ott 2026 la chiavetta e' sparita da lsusb dopo
# l'avvio delle 10:00 e un riavvio l'ha ripristinata: qui lo fa da solo, con dei limiti.
#
# Impostazioni in /etc/default/ogn-boot-setup:
#   WATCHDOG_USB=off|prova|on     off (default) = non fa niente; prova = scrive nel log cosa farebbe
#                                 ma NON riavvia; on = riavvia davvero
#   WATCHDOG_MAX=2                riavvii massimi al giorno (default 2)
# Regole: aspetta 4 minuti dall'avvio; il guasto deve durare almeno due controlli consecutivi
# (circa 5 minuti); niente riavvio nei 45 minuti prima dello spegnimento serale e dopo; al massimo
# WATCHDOG_MAX riavvii al giorno. Ogni decisione e' una riga in ogn-eventi.log.
# Variabili per le prove: LSUSB_CMD, UNITA_RF, EVENTI, STATODIR, ORA_UTC (HHMM), SHUTDOWN_HHMM, UPTIME_S, REBOOT_CMD.

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"   # il cron ha un PATH ridotto
[ -f /etc/default/ogn-boot-setup ] && . /etc/default/ogn-boot-setup
MODO=${WATCHDOG_USB:-off}
[ "$MODO" = "off" ] && exit 0
MAX=${WATCHDOG_MAX:-2}
UNITA_RF=${UNITA_RF:-rtlsdr-ogn}
EVENTI=${EVENTI:-/boot/ogn-eventi.log}
STATODIR=${STATODIR:-/var/lib/ogn-watchdog}
LSUSB_CMD=${LSUSB_CMD:-lsusb}
REBOOT_CMD=${REBOOT_CMD:-/bin/systemctl reboot}
mkdir -p "$STATODIR"

SU=${UPTIME_S:-$(cut -d. -f1 /proc/uptime)}
[ "$SU" -lt 240 ] && exit 0                       # l'avvio non e' ancora assestato

OGGI=$(date -u +%F)
NOW=$(date +%s)
log() { echo "$(date -u '+%F %T') UTC watchdog-usb $*" >> "$EVENTI"; }

# --- la chiavetta e' a posto? ---
MOTIVO=""
if ! $LSUSB_CMD 2>/dev/null | grep -qiE 'ID 0bda:28(32|38)'; then
  MOTIVO="chiavetta assente da lsusb"
else
  ULT=$(journalctl -b -u "$UNITA_RF" -o short-unix --no-pager 2>/dev/null | grep -a 'Cannot open device' | tail -1 | cut -d. -f1)
  if [ -n "$ULT" ] && [ $(( NOW - ULT )) -lt 150 ]; then MOTIVO="ogn-rf non riesce ad aprire la chiavetta"; fi
fi

if [ -z "$MOTIVO" ]; then rm -f "$STATODIR/guasto-da"; exit 0; fi

# --- il guasto deve durare almeno due controlli consecutivi ---
if [ ! -f "$STATODIR/guasto-da" ]; then echo "$NOW" > "$STATODIR/guasto-da"; log "guasto visto ($MOTIVO), ricontrollo al prossimo giro"; exit 0; fi
DA=$(cat "$STATODIR/guasto-da"); [ $(( NOW - DA )) -lt 240 ] && exit 0

# --- limiti ---
N=0; [ -f "$STATODIR/riavvii-$OGGI" ] && N=$(cat "$STATODIR/riavvii-$OGGI")
if [ "$N" -ge "$MAX" ]; then
  [ ! -f "$STATODIR/limite-$OGGI" ] && { log "limite di $MAX riavvii al giorno raggiunto: non riavvio ($MOTIVO)"; : > "$STATODIR/limite-$OGGI"; }
  exit 0
fi
# l'ora dello spegnimento e' nelle righe di cron che contengono 'shutdown -h' (la riga --notte, 5 minuti prima, non conta)
SH=${SHUTDOWN_HHMM:-$(crontab -l 2>/dev/null | grep 'shutdown -h' | grep -o '= "[0-9][0-9][0-9][0-9]"' | tr -dc '0-9\n' | sort | head -1)}
if [ -n "$SH" ]; then
  A=${ORA_UTC:-$(date -u +%H%M)}
  m() { echo $(( 10#${1:0:2} * 60 + 10#${1:2:2} )); }
  if [ $(( $(m "$SH") - $(m "$A") )) -lt 45 ]; then
    [ ! -f "$STATODIR/sera-$OGGI" ] && { log "troppo vicino allo spegnimento serale ($SH UTC): non riavvio ($MOTIVO)"; : > "$STATODIR/sera-$OGGI"; }
    exit 0
  fi
fi

# --- azione ---
if [ "$MODO" = "prova" ]; then
  log "PROVA: avrei riavviato ($MOTIVO), riavvio $((N+1)) di $MAX"
  echo "$NOW" > "$STATODIR/guasto-da"             # nel modo prova ripete il messaggio al massimo ogni 5 minuti
  exit 0
fi
echo $((N+1)) > "$STATODIR/riavvii-$OGGI"
rm -f "$STATODIR/guasto-da"
log "riavvio $((N+1)) di $MAX ($MOTIVO)"
sync
$REBOOT_CMD
