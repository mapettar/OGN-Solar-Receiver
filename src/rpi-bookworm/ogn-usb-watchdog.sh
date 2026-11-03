#!/bin/bash
# ogn-usb-watchdog.sh v1.2 - controlla che la chiavetta RTL-SDR e ogn-rf lavorino e interviene a gradini.
# Si lancia da cron ogni 5 minuti (come root).
#   1) chiavetta assente da lsusb, oppure ogn-rf non riesce ad aprirla  -> RIAVVIA LA PI
#   2) chiavetta presente ma ogn-rf quasi inattivo (CPU sotto il 5%)    -> RIAVVIA SOLO I SERVIZI
#      (rtlsdr-ogn e ogn-decode); se i riavvii dei servizi del giorno sono finiti, passa al gradino 1.
# Storia: 31 ott 2026 la chiavetta non era rilevata dopo l'avvio; 3 nov 2026 e' caduta dal bus dopo 7 minuti
# (errori USB -110/-71) e dopo il riavvio ogn-rf e' rimasto inattivo (0% CPU) finche' non sono stati
# riavviati i servizi.
#
# Impostazioni in /etc/default/ogn-boot-setup:
#   WATCHDOG_USB=off|prova|on     off (default) = non fa niente; prova = scrive nel log cosa farebbe
#                                 ma NON interviene; on = interviene davvero
#   WATCHDOG_MAX=2                riavvii della Pi al giorno (default 2)
#   WATCHDOG_SERVIZI_MAX=3        riavvii dei soli servizi al giorno (default 3)
# Regole: aspetta 4 minuti dall'avvio (6 per il controllo della CPU); il guasto deve durare almeno due
# controlli consecutivi (circa 5 minuti); niente riavvio della Pi nei 45 minuti prima dello spegnimento
# serale. Ogni decisione e' una riga in ogn-eventi.log.
# Variabili per le prove: LSUSB_CMD, UNITA_RF, UNITA_DECODE, EVENTI, STATODIR, ORA_UTC (HHMM), SHUTDOWN_HHMM,
# UPTIME_S, CPU_RF (percentuale simulata), REBOOT_CMD, RESTART_CMD.

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"   # il cron ha un PATH ridotto
[ -f /etc/default/ogn-boot-setup ] && . /etc/default/ogn-boot-setup
MODO=${WATCHDOG_USB:-off}
[ "$MODO" = "off" ] && exit 0
MAX=${WATCHDOG_MAX:-2}
SMAX=${WATCHDOG_SERVIZI_MAX:-3}
UNITA_RF=${UNITA_RF:-rtlsdr-ogn}
UNITA_DECODE=${UNITA_DECODE:-ogn-decode}
EVENTI=${EVENTI:-/boot/ogn-eventi.log}
STATODIR=${STATODIR:-/var/lib/ogn-watchdog}
LSUSB_CMD=${LSUSB_CMD:-lsusb}
REBOOT_CMD=${REBOOT_CMD:-/bin/systemctl reboot}
RESTART_CMD=${RESTART_CMD:-/bin/systemctl restart $UNITA_RF $UNITA_DECODE}
mkdir -p "$STATODIR"

SU=${UPTIME_S:-$(cut -d. -f1 /proc/uptime)}
[ "$SU" -lt 240 ] && exit 0                       # l'avvio non e' ancora assestato

OGGI=$(date -u +%F)
NOW=$(date +%s)
log() { echo "$(date -u '+%F %T') UTC watchdog-usb $*" >> "$EVENTI"; }

# CPU di ogn-rf sul momento, misurata su 3 secondi (stesso metodo di "stato", con una finestra piu' lunga)
cpu_rf() {
  [ -n "${CPU_RF:-}" ] && { echo "$CPU_RF"; return; }
  local pid t1 t2 hz
  pid=$(pgrep -x ogn-rf 2>/dev/null | head -1); [ -n "$pid" ] || { echo -1; return; }
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  t1=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null) || { echo -1; return; }
  sleep 3
  t2=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null) || { echo -1; return; }
  echo $(( (t2 - t1) * 100 / (hz * 3) ))
}

# --- classificazione ---
TIPO=""; MOTIVO=""
if ! $LSUSB_CMD 2>/dev/null | grep -qiE 'ID 0bda:28(32|38)'; then
  TIPO=pi; MOTIVO="chiavetta assente da lsusb"
else
  ULT=$(journalctl -b -u "$UNITA_RF" -o short-unix --no-pager 2>/dev/null | grep -a 'Cannot open device' | tail -1 | cut -d. -f1)
  if [ -n "$ULT" ] && [ $(( NOW - ULT )) -lt 150 ]; then
    TIPO=pi; MOTIVO="ogn-rf non riesce ad aprire la chiavetta"
  elif [ "$SU" -ge 360 ]; then
    C=$(cpu_rf)
    if [ "$C" -ge 0 ] && [ "$C" -lt 5 ]; then TIPO=servizi; MOTIVO="ogn-rf quasi inattivo ($C% CPU) con la chiavetta presente"
    elif [ "$C" -lt 0 ]; then TIPO=servizi; MOTIVO="processo ogn-rf non trovato"; fi
  fi
fi

if [ -z "$TIPO" ]; then rm -f "$STATODIR/guasto-da"; exit 0; fi

# --- il guasto deve durare almeno due controlli consecutivi (stesso tipo) ---
if [ -f "$STATODIR/guasto-da" ]; then read -r T_OLD DA < "$STATODIR/guasto-da"; else T_OLD=""; DA=0; fi
if [ "$T_OLD" != "$TIPO" ]; then
  echo "$TIPO $NOW" > "$STATODIR/guasto-da"
  log "guasto visto ($MOTIVO), ricontrollo al prossimo giro"
  exit 0
fi
[ $(( NOW - DA )) -lt 240 ] && exit 0

# --- gradino 2: solo i servizi ---
if [ "$TIPO" = "servizi" ]; then
  NS=0; [ -f "$STATODIR/servizi-$OGGI" ] && NS=$(cat "$STATODIR/servizi-$OGGI")
  if [ "$NS" -lt "$SMAX" ]; then
    if [ "$MODO" = "prova" ]; then
      log "PROVA: avrei riavviato i servizi ($MOTIVO), servizi $((NS+1)) di $SMAX"
      echo "$TIPO $NOW" > "$STATODIR/guasto-da"; exit 0
    fi
    echo $((NS+1)) > "$STATODIR/servizi-$OGGI"
    rm -f "$STATODIR/guasto-da"
    log "riavvio servizi $((NS+1)) di $SMAX ($MOTIVO)"
    $RESTART_CMD
    exit 0
  fi
  MOTIVO="$MOTIVO; riavvii dei servizi del giorno esauriti"   # si passa al gradino 1
fi

# --- gradino 1: riavvio della Pi, con i limiti ---
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
if [ "$MODO" = "prova" ]; then
  log "PROVA: avrei riavviato la Pi ($MOTIVO), riavvio $((N+1)) di $MAX"
  echo "$TIPO $NOW" > "$STATODIR/guasto-da"
  exit 0
fi
echo $((N+1)) > "$STATODIR/riavvii-$OGGI"
rm -f "$STATODIR/guasto-da"
log "riavvio $((N+1)) di $MAX ($MOTIVO)"
sync
$REBOOT_CMD
