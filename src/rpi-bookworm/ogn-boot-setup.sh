#!/bin/bash
# ogn-boot-setup.sh v1.0 - adattamento di setup_cron.sh v1.7 a Raspberry Pi OS Bookworm (Pi 3A+)
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

# Attesa sincronizzazione dell'ora di sistema (max 6 x 20 s)
NTP_OK=0
for i in 1 2 3 4 5 6; do
  if [ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ]; then NTP_OK=1; break; fi
  sleep 20
done
echo "NTP_OK=$NTP_OK SCHEDULE=$SCHEDULE"

to_bcd() { printf '%02x' $(( $1 / 10 * 16 + $1 % 10 )); }

if [ "$NTP_OK" -eq 1 ]; then
  # Scrive l'ora UTC sul DS3231 e azzera il flag OSF (l'ATtiny considera l'orologio perso finche OSF=1)
  T=$(date -u +%H:%M:%S)
  H=$((10#${T:0:2})); M=$((10#${T:3:2})); S=$((10#${T:6:2}))
  if i2cset -y 1 0x68 0x02 0x$(to_bcd $H) && \
     i2cset -y 1 0x68 0x01 0x$(to_bcd $M) && \
     i2cset -y 1 0x68 0x00 0x$(to_bcd $S) && \
     i2cset -y 1 0x68 0x0f 0x00; then
    echo "DS3231 scritto: $T UTC (stato letto: $(i2cget -y 1 0x68 0x0f))"
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
