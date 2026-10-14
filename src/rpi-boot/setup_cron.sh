#!/bin/bash
# /boot/setup_cron.sh v1.7 - eseguito ad ogni avvio (runAtBoot in OGN-receiver.conf)
# Log di questa esecuzione: cat /tmp/setup_cron.log
exec >> /tmp/setup_cron.log 2>&1
echo "=== setup_cron.sh $(date -u '+%F %T') UTC ==="

export PYTHONPATH="/boot/python-libs:$PYTHONPATH"

# Chiave Tailscale: metti qui la TUA chiave (Reusable, No expiry).
# Non pubblicarla mai su GitHub / in chat. Lascia il segnaposto per disattivare.
TS_AUTHKEY="tskey-auth-XXXXXXXXXXXX"

# 1. Timezone italiana e attesa rete
timedatectl set-timezone Europe/Rome
sleep 60

# 2. NTP con 6 tentativi (ntpdate ritorna 0 solo se sincronizza)
NTP_OK=0
for i in 1 2 3 4 5 6; do
  if ntpdate -u pool.ntp.org; then NTP_OK=1; break; fi
  sleep 20
done
echo "NTP_OK=$NTP_OK"

# 3. I2C e strumenti (l'overlay perde i pacchetti ad ogni reboot)
modprobe i2c-dev
modprobe i2c-bcm2835
which i2cset > /dev/null 2>&1 || apt-get install -y i2c-tools > /dev/null 2>&1

to_bcd() { printf '%02x' $(( $1 / 10 * 16 + $1 % 10 )); }

if [ "$NTP_OK" -eq 1 ]; then
  # 4. Scrive l'ora UTC sul DS3231 e azzera il flag "oscillatore fermato" (OSF).
  #    Finche OSF=1 l'ATtiny considera l'orologio perso (vedi sketch v1.7).
  T=$(date -u +%H:%M:%S)
  H=$((10#${T:0:2})); M=$((10#${T:3:2})); S=$((10#${T:6:2}))
  i2cset -y 1 0x68 0x02 0x$(to_bcd $H)
  i2cset -y 1 0x68 0x01 0x$(to_bcd $M)
  i2cset -y 1 0x68 0x00 0x$(to_bcd $S)
  i2cset -y 1 0x68 0x0f 0x00
  echo "DS3231 scritto: $T UTC"
  # 5. Tramonto da effemeridi: crontab shutdown + taglio rele (max 17:00 UTC)
  python3 /boot/calc_sunset.py
else
  # Senza NTP l'ora di sistema non e affidabile: non toccare il DS3231,
  # usa solo gli orari fissi di sicurezza (shutdown 16:55 UTC, taglio 17:00 UTC)
  echo "NTP non disponibile: modalita fallback"
  python3 /boot/calc_sunset.py --fallback
fi

# 6. Altri pacchetti (non critici)
which screen  > /dev/null 2>&1 || apt-get install -y screen  > /dev/null 2>&1
which minicom > /dev/null 2>&1 || apt-get install -y minicom > /dev/null 2>&1
which pppd    > /dev/null 2>&1 || apt-get install -y ppp     > /dev/null 2>&1

# 7. Tailscale (accesso SSH remoto)
if [ "$TS_AUTHKEY" != "tskey-auth-XXXXXXXXXXXX" ]; then
  which tailscale > /dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
  tailscale up --authkey="$TS_AUTHKEY" --accept-routes
fi

# 8. (opzionale) log batteria INA219 ogni 10 minuti
# (crontab -u root -l; echo "*/10 * * * * python3 /boot/monitor_batteria.py >> /tmp/batteria.log 2>&1") | crontab -u root -

echo "=== fine setup_cron.sh ==="

# 9. Registro che sopravvive allo spegnimento (in /boot): ultimo log + riga per ogni avvio
cp /tmp/setup_cron.log /boot/setup_cron.last.log
echo "$(date -u '+%F %T') UTC avvio NTP_OK=$NTP_OK" >> /boot/ogn-eventi.log
tail -n 200 /boot/ogn-eventi.log > /tmp/ogn-eventi.tmp && cat /tmp/ogn-eventi.tmp > /boot/ogn-eventi.log
sync
