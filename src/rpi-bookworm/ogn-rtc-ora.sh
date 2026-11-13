#!/bin/bash
# ogn-rtc-ora.sh v1.0 - all'avvio mette l'ora del DS3231 nell'orologio di sistema, PRIMA della rete e dei servizi.
# Installazione: /usr/local/sbin/ogn-rtc-ora.sh (root:root, 755), lanciato da ogn-rtc-ora.service.
# Perche': senza rete (Wi-Fi assente, SIM che ancora si registra) l'ora di sistema all'avvio e' quella salvata da
# fake-hwclock allo spegnimento (in ritardo di ore) e gli eventi dell'avvio escono con data e ora sbagliate.
# Come: ogn-boot-setup scrive sul DS3231 solo ore:minuti:secondi, in UTC piu' lo spostamento di calc_sunset.py --shift
# (0 con l'ora legale, -1 con l'ora solare), senza data. Quindi si ricava solo l'ora del giorno e la data resta quella
# di sistema: l'ora giusta e' la prima volta DOPO l'ora salvata (l'orologio da fake-hwclock e' sempre in ritardo).
# Non fa niente se: l'ora e' gia' sincronizzata da NTP, il DS3231 non risponde (la Zero 2 W non ce l'ha) o ha perso l'ora (OSF).
# Se la stazione e' stata spenta per piu' giorni la data resta quella dell'ultimo spegnimento fino all'arrivo di NTP.
I2CGET=${I2CGET:-i2cget}
EVENTI=${EVENTI:-/boot/ogn-eventi.log}
CALC=${CALC:-/usr/local/sbin/calc_sunset.py}
TOLLERANZA=120

ntp_sincronizzato() {
  if command -v ntpq >/dev/null 2>&1 && systemctl is-active --quiet ntp 2>/dev/null; then
    ntpq -pn 2>/dev/null | grep -q '^\*'
  elif [ -e /run/systemd/timesync/synchronized ]; then
    return 0
  else
    return 1
  fi
}

if [ -z "$OGN_TEST" ]; then
  if ntp_sincronizzato; then echo "ora gia' sincronizzata da NTP: niente da fare"; exit 0; fi
  modprobe i2c-dev 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/i2c-1 ] && break; sleep 1; done
fi

ST=$($I2CGET -y 1 0x68 0x0f 2>/dev/null) || { echo "DS3231 non risponde su 0x68: niente da fare"; exit 0; }
HH=$($I2CGET -y 1 0x68 0x02 2>/dev/null) || exit 0
MM=$($I2CGET -y 1 0x68 0x01 2>/dev/null) || exit 0
SS=$($I2CGET -y 1 0x68 0x00 2>/dev/null) || exit 0
if [ $(( ST & 0x80 )) -ne 0 ]; then echo "DS3231: OSF acceso, ora persa: niente da fare"; exit 0; fi
from_bcd() { local v=$(( $1 )); echo $(( (v >> 4) * 10 + (v & 15) )); }
H=$(from_bcd $(( HH & 0x3f ))); M=$(from_bcd "$MM"); S=$(from_bcd "$SS")
if [ "$H" -ge 24 ] || [ "$M" -ge 60 ] || [ "$S" -ge 60 ]; then echo "DS3231: valori non validi ($H:$M:$S): niente da fare"; exit 0; fi

SHIFT=${OGN_SHIFT:-$(python3 "$CALC" --shift 2>/dev/null)}
SHIFT=${SHIFT:-0}
case "$SHIFT" in 0|-1|1|-2|2) ;; *) SHIFT=0 ;; esac

DS_SEC=$(( H * 3600 + M * 60 + S ))
UTC_SEC=$(( (DS_SEC - SHIFT * 3600 + 86400) % 86400 ))
NOW=${OGN_TEST_NOW:-$(date -u +%s)}
NOW_SEC=$(( NOW % 86400 ))
DELTA=$(( (UTC_SEC - NOW_SEC + 86400) % 86400 ))
if [ "$DELTA" -lt "$TOLLERANZA" ] || [ "$DELTA" -gt $(( 86400 - TOLLERANZA )) ]; then
  echo "ora di sistema gia' giusta entro $TOLLERANZA s (DS3231 $H:$M:$S, spostamento $SHIFT)"
  exit 0
fi
NEW=$(( NOW + DELTA ))
PRIMA=$(date -u -d "@$NOW" '+%F %T')
${OGN_SETDATE:-date} -u -s "@$NEW" >/dev/null
DOPO=$(date -u -d "@$NEW" '+%F %T')
echo "ora impostata dal DS3231: $PRIMA -> $DOPO UTC (DS3231 $H:$M:$S, spostamento $SHIFT)"
echo "$DOPO UTC ora dal DS3231 (l'orologio di sistema era fermo a $PRIMA, ritardo $(( DELTA / 60 )) min)" >> "$EVENTI" 2>/dev/null
exit 0
