#!/bin/bash
# ds3231_log.sh v1.0 (Bookworm) - una riga al minuto: ora del DS3231, stato e differenza dall'ora attesa.
# L'ora attesa e' UTC + scarto (0 in ora legale, -1 in ora solare), cioe' ora locale - 2 h.
# Quindi "diff" vicino a 0 (0 o -1 s) e' normale in ogni stagione.
# Formato: AAAA-MM-GG HH:MM:SS(UTC) ds=HH:MM:SS st=0xNN diff=Ns
# Una lettura fallita scrive "ds=Error: Read failed" (lo script stato la conta).
PATH=$PATH:/usr/sbin:/sbin
LOG=${DS3231_LOG:-/var/log/ds3231.log}
ADESSO=$(date -u '+%F %T')

S=$(i2cget -y 1 0x68 0x00 2>/dev/null); M=$(i2cget -y 1 0x68 0x01 2>/dev/null)
H=$(i2cget -y 1 0x68 0x02 2>/dev/null); ST=$(i2cget -y 1 0x68 0x0f 2>/dev/null)
if [ -z "$S" ] || [ -z "$M" ] || [ -z "$H" ] || [ -z "$ST" ]; then
  echo "$ADESSO ds=Error: Read failed st=n/d diff=n/d" >> "$LOG"
  exit 0
fi

bcd() { local v=$(( $1 )); echo $(( (v >> 4) * 10 + (v & 15) )); }
HH=$(bcd $(( H & 0x3F ))); MM=$(bcd "$M"); SS=$(bcd "$S")
DS=$(( HH * 3600 + MM * 60 + SS ))

OFF=$(date +%z)                                  # es. +0100 (solare) o +0200 (legale)
OFF_H=$(( 10#${OFF:1:2} )); [ "${OFF:0:1}" = "-" ] && OFF_H=$(( -OFF_H ))
SCARTO=$(( OFF_H - 2 ))
ATTESA=$(( ( $(date -u +%s) % 86400 + SCARTO * 3600 + 86400 ) % 86400 ))
D=$(( DS - ATTESA ))
[ $D -gt 43200 ] && D=$(( D - 86400 ))
[ $D -lt -43200 ] && D=$(( D + 86400 ))

printf '%s ds=%02d:%02d:%02d st=%s diff=%ds\n' "$ADESSO" "$HH" "$MM" "$SS" "$ST" "$D" >> "$LOG"
