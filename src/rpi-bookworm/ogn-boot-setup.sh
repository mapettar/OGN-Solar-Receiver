#!/bin/bash
# ogn-boot-setup.sh v1.3 (log di ora e stato DS3231 PRIMA della scrittura, avviso OSF; v1.2 DS3231 = ora locale - 2 h: avvio sempre alle 10 locali; v1.1 controllo ntpq) - adattamento di setup_cron.sh v1.7 a Raspberry Pi OS Bookworm (Pi 3A+)
# Installazione: /usr/local/sbin/ogn-boot-setup.sh (root:root, 755), lanciato da ogn-boot-setup.service.
# - NON installa pacchetti e NON tocca Tailscale (gia installato a mano).
# - NON usa l'overlay RTC del kernel: il DS3231 si scrive con i2cset all'indirizzo 0x68.
# - SCHEDULE=on  : scrive l'ora sul DS3231 e lancia calc_sunset.py (shutdown serale + taglio rele)
#   SCHEDULE=off : scrive solo l'ora sul DS3231 (stazione di prova con rele escluso)
#   Si imposta in /etc/default/ogn-boot-setup (file assente = on).
LOG=/var/log/ogn-boot-setup.log
exec >> "$LOG" 2>&1
echo "=== ogn-boot-setup $(date -u '+%F %T') UTC ==="

SCHEDULE=on
[ -f /etc/default/ogn-boot-setup ] && . /etc/default/ogn-boot-setup
CALC=/usr/local/sbin/calc_sunset.py
EVENTI=/boot/ogn-eventi.log

timedatectl set-timezone Europe/Rome
modprobe i2c-dev

# Sincronizzazione VERA dell'ora di sistema. Il flag NTPSynchronized di timedatectl NON e affidabile
# qui: con ntpd puo valere "yes" mentre l'ora e ancora quella vecchia salvata da fake-hwclock
# (v1.0 scriveva quell'ora sul DS3231 a ogni avvio). Si considera sincronizzato solo quando ntpd ha
# scelto un server (riga che inizia con "*" in ntpq -pn) o, con timesyncd, esiste il file
# /run/systemd/timesync/synchronized. Se nessuno dei due e disponibile: NTP_OK=0, il DS3231 non si tocca.
ntp_sincronizzato() {
  if command -v ntpq >/dev/null 2>&1 && systemctl is-active --quiet ntp; then
    ntpq -pn 2>/dev/null | grep -q '^\*'
  elif [ -e /run/systemd/timesync/synchronized ]; then
    return 0
  else
    return 1
  fi
}
# Attesa max 18 x 10 s (TimeoutStartSec=300)
NTP_OK=0
for i in $(seq 1 18); do
  if ntp_sincronizzato; then NTP_OK=1; break; fi
  sleep 10
done
echo "NTP_OK=$NTP_OK SCHEDULE=$SCHEDULE"

to_bcd() { printf '%02x' $(( $1 / 10 * 16 + $1 % 10 )); }

# Stato del DS3231 PRIMA di toccarlo: l'OSF acceso vuol dire ora persa (la scrittura sotto lo azzera).
PRE_ST=$(i2cget -y 1 0x68 0x0f 2>/dev/null)
PRE_H=$(i2cget -y 1 0x68 0x02 2>/dev/null); PRE_M=$(i2cget -y 1 0x68 0x01 2>/dev/null); PRE_S=$(i2cget -y 1 0x68 0x00 2>/dev/null)
if [ -n "$PRE_ST" ] && [ -n "$PRE_H" ] && [ -n "$PRE_M" ] && [ -n "$PRE_S" ]; then
  echo "DS3231 PRIMA della scrittura: ${PRE_H#0x}:${PRE_M#0x}:${PRE_S#0x} (BCD), stato $PRE_ST"
  if [ $(( PRE_ST & 0x80 )) -ne 0 ]; then
    echo "ATTENZIONE: OSF acceso, il DS3231 aveva perso l'ora"
    echo "$(date -u '+%F %T') UTC DS3231 ora persa (OSF acceso, stato $PRE_ST)" >> "$EVENTI"
  fi
else
  echo "DS3231 PRIMA della scrittura: non risponde su 0x68"
fi

if [ "$NTP_OK" -eq 1 ]; then
  # Scrive sul DS3231 UTC + shift (0 ora legale, -1 ora solare) e azzera il flag OSF
  # (l'ATtiny considera l'orologio perso finche OSF=1). Cosi lo sketch (soglia 08:00) parte sempre alle 10:00 locali.
  SHIFT=$(python3 "$CALC" --shift 2>/dev/null); SHIFT=${SHIFT:-0}
  T=$(date -u -d "$SHIFT hours" +%H:%M:%S)
  H=$((10#${T:0:2})); M=$((10#${T:3:2})); S=$((10#${T:6:2}))
  if i2cset -y 1 0x68 0x02 0x$(to_bcd $H) && \
     i2cset -y 1 0x68 0x01 0x$(to_bcd $M) && \
     i2cset -y 1 0x68 0x00 0x$(to_bcd $S) && \
     i2cset -y 1 0x68 0x0f 0x00; then
    echo "DS3231 scritto: $T (UTC${SHIFT:+ $SHIFT h}; stato dopo azzeramento: $(i2cget -y 1 0x68 0x0f))"
  else
    echo "ERRORE: scrittura DS3231 fallita (controllare I2C e indirizzo 0x68)"
  fi
  if [ "$SCHEDULE" = "on" ]; then
    python3 "$CALC"
  else
    echo "SCHEDULE=off: calc_sunset.py non eseguito"
  fi
else
  echo "NTP non disponibile: DS3231 non toccato"
  if [ "$SCHEDULE" = "on" ]; then
    python3 "$CALC" --fallback
  fi
fi

# Registro eventi (rootfs persistente: /boot e una directory normale)
echo "$(date -u '+%F %T') UTC avvio NTP_OK=$NTP_OK SCHEDULE=$SCHEDULE" >> "$EVENTI"
tail -n 200 "$EVENTI" > /tmp/ogn-eventi.tmp && cat /tmp/ogn-eventi.tmp > "$EVENTI"
echo "=== fine ogn-boot-setup ==="
sync
