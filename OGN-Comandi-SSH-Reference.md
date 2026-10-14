# Comandi SSH - Stazione OGN Solare
## Guida rapida verifica, controllo e ripristino (v1.7)

**Connessione SSH** (sostituisci l'IP con il tuo; la password è `piUserPassword`):
```bash
ssh pi@192.168.178.120          # rete locale
ssh pi@<IP-TAILSCALE>           # da remoto via Tailscale
ssh-keygen -R <IP>              # se la chiave host è cambiata (nuova SD/RPi)
```

> Non incollare mai password o chiavi Tailscale in chat o su GitHub.

---

## 1. VERIFICA SISTEMA

```bash
date; date -u                    # ora locale e UTC
timedatectl                      # timezone (Europe/Rome) e NTP
df -h; lsblk                     # spazio e SD
overlayctl status                # overlay attivo?
cat /tmp/setup_cron.log          # esito dell'ultimo avvio (solo finché la RPi resta accesa: /tmp è in RAM)
cat /boot/ogn-eventi.log         # avvii e shutdown dei giorni scorsi (persistente)
cat /boot/setup_cron.last.log    # log completo dell'ultimo avvio (persistente)
vcgencmd measure_temp            # temperatura CPU
```

---

## 2. DS3231 (RTC)

```bash
sudo modprobe i2c-dev
sudo i2cdetect -y 1              # devono comparire 40 (INA219), 57 e 68
sudo i2cget -y 1 0x68 0x02       # ore UTC (BCD)
sudo i2cget -y 1 0x68 0x01       # minuti
sudo i2cget -y 1 0x68 0x00       # secondi
sudo i2cget -y 1 0x68 0x0f       # bit 7 (0x80) = orologio perso (OSF); 0x00 = valido
```

### Taglio relè (registro allarme, scritto da calc_sunset.py)
```bash
sudo i2cget -y 1 0x68 0x09       # ore UTC (BCD) - massimo 0x17
sudo i2cget -y 1 0x68 0x08       # minuti (BCD)
```

### Scrivere l'ora sul DS3231 (UTC) e azzerare OSF
```bash
T=$(date -u +%H:%M:%S)
H=$((10#${T:0:2})); M=$((10#${T:3:2})); S=$((10#${T:6:2}))
b() { printf '%02x' $(( $1 / 10 * 16 + $1 % 10 )); }
sudo i2cset -y 1 0x68 0x02 0x$(b $H)
sudo i2cset -y 1 0x68 0x01 0x$(b $M)
sudo i2cset -y 1 0x68 0x00 0x$(b $S)
sudo i2cset -y 1 0x68 0x0f 0x00      # OSF a 0
```
(prima assicurati che `date -u` sia corretta: `sudo ntpdate -u pool.ntp.org`)

### Azzerare a mano il flag "orologio perso" (OSF)
```bash
sudo i2cget -y 1 0x68 0x0f           # 0x80 o 0x88 = OSF a 1 → l'ATtiny cicla 2h ON / 30 min OFF
sudo i2cset -y 1 0x68 0x0f 0x00      # azzera; il setup_cron.sh v1.7 lo fa ad ogni avvio
```

### Simulare la perdita dell'ora (prova sul banco)
```bash
sudo i2cset -y 1 0x68 0x02 0x00
sudo i2cset -y 1 0x68 0x01 0x00
sudo i2cset -y 1 0x68 0x0f 0x80      # OSF = 1 → l'ATtiny accende il relè entro 30 s
```

### Conversione decimale → BCD
```
ore 8  → 0x08    ore 16 → 0x16    minuti 5  → 0x05    minuti 30 → 0x30
ore 9  → 0x09    ore 17 → 0x17    minuti 10 → 0x10    minuti 45 → 0x45
ore 10 → 0x10    ore 18 → 0x18    minuti 15 → 0x15    minuti 55 → 0x55
```

---

## 3. CRONTAB E SHUTDOWN

```bash
sudo crontab -l                       # 3 righe '[ "$(date -u +%H%M)" = "HHMM" ] && shutdown' (shutdown, failsafe, 1700)
sudo python3 /boot/calc_sunset.py     # ricalcola tramonto, crontab e taglio relè
sudo python3 /boot/calc_sunset.py --fallback   # solo orari fissi 16:55 / 17:00 UTC
sudo systemctl status cron
sudo grep CRON /var/log/syslog | tail -20
sudo /sbin/shutdown -h now            # spegnimento manuale
```

Le righe di shutdown scattano **ogni minuto** e confrontano `date -u`, quindi non dipendono dal fuso del demone cron. Per provare come il demone legge gli orari (due righe a un minuto preciso, una locale e una UTC):
```bash
T=$(date -d '+3 min' +%M); HL=$(date -d '+3 min' +%-H); HU=$(date -u -d '+3 min' +%-H)
(sudo crontab -l; echo "$T $HL * * * echo LOCALE >> /tmp/crontest2.log"; echo "$T $HU * * * echo UTC >> /tmp/crontest2.log") | sudo crontab -
sleep 240; cat /tmp/crontest2.log; date; date -u
sudo crontab -l | grep -v crontest2 | sudo crontab -     # rimuove le righe di prova
```

---

## 4. NTP

```bash
sudo ntpdate -u pool.ntp.org          # ritorna 0 se riesce
timedatectl | grep synchronized
```

---

## 5. OGN RECEIVER

```bash
sudo systemctl status ogn
sudo journalctl -u ogn -f
cat /tmp/glidernet-autossh.log
ps aux | grep -E "ogn|ppp|autossh"
```

---

## 6. FILE IN /boot

```bash
ls -la /boot
cat /boot/OGN-receiver.conf
cat /boot/config.txt
cat /boot/setup_cron.sh               # contiene la chiave Tailscale: non copiarla in chat
cat /boot/calc_sunset.py
sudo nano /boot/setup_cron.sh         # modifica (persistente)
sudo bash /boot/setup_cron.sh         # esecuzione manuale
```

---

## 7. RETE E TAILSCALE

```bash
hostname -I
ip addr show
ping -c 3 8.8.8.8
tailscale ip
tailscale status
sudo tailscale up --authkey=<LA-TUA-CHIAVE> --accept-routes
```

---

## 8. BATTERIA (INA219) E ADC

```bash
python3 /boot/monitor_batteria.py     # tensione, corrente, potenza
sudo i2cdetect -y 1                   # 40 = INA219
```

L'ADC dell'ATtiny non è leggibile dalla RPi: misura con il multimetro sul pin P4 del Digispark.

### Tabella Li-ion 3S (R1 = 56 kΩ, R2 = 10 kΩ, VCC ≈ 4.8 V)
```
Batteria    P4       ADC     Stato
12.6V   →  1.91V  →  407  →  Piena
12.0V   →  1.82V  →  388  →  Buona
11.1V   →  1.68V  →  358  →  Nominale
10.5V   →  1.59V  →  339  →  Riaccensione (SOGLIA_BATT_ON = 340)
10.2V   →  1.55V  →  329  →  Bassa
 9.6V   →  1.46V  →  310  →  Spegnimento (SOGLIA_BATT_MIN = 310)
 9.0V   →  1.36V  →  291  →  Pericolosa
```

---

## 9. PYTHON-LIBS PERSISTENTI (INA219)

```bash
pip3 install --target=/home/pi/python-libs adafruit-circuitpython-ina219
# se pip rifiuta: aggiungere --break-system-packages
sudo cp -r /home/pi/python-libs /boot/python-libs
ls /boot/python-libs
```

---

## 10. OVERLAY FILESYSTEM

```bash
overlayctl status
sudo overlayctl disable && sudo reboot    # per modificare file fuori da /boot
sudo overlayctl enable  && sudo reboot    # a lavoro finito: protegge la SD
```

---

## 11. RIPRISTINO SU NUOVA SD / NUOVA RPi

### A) Da immagine OGN pulita + backup di /boot (dal Mac)

```bash
# 1. scrivi l'immagine OGN sulla SD con Raspberry Pi Imager o balenaEtcher
#    (http://download.glidernet.org/seb-ogn-rpi-image)

# 2. smonta e rimonta la SD: compare /Volumes/boot
cd ~/Desktop/ogn-boot-backup
cp OGN-receiver.conf setup_cron.sh calc_sunset.py monitor_batteria.py /Volumes/boot/
cp -R python-libs /Volumes/boot/
cat >> /Volumes/boot/config.txt <<'EOT'
dtparam=i2c_arm=on
enable_uart=1
EOT
dot_clean /Volumes/boot
sed -i '' 's/\r$//' /Volumes/boot/setup_cron.sh /Volumes/boot/calc_sunset.py
diskutil eject /Volumes/boot
```

```bash
# 3. inserisci la SD, alimenta la RPi, attendi 3-5 minuti (espansione SD, riavvii)
ping raspberrypi.local            # oppure cerca l'IP nel router
ssh-keygen -R <IP>
ssh pi@<IP>
```

```bash
# 4. verifiche sulla RPi
df -h; overlayctl status
cat /tmp/setup_cron.log
date; timedatectl
sudo crontab -l
sudo modprobe i2c-dev; sudo i2cdetect -y 1
sudo i2cget -y 1 0x68 0x0f        # 0x00 = ok
sudo systemctl status ogn
tailscale status
```

```bash
# 5. se qualcosa manca
sudo bash /boot/setup_cron.sh; cat /tmp/setup_cron.log
pip3 install --target=/home/pi/python-libs adafruit-circuitpython-ina219
sudo cp -r /home/pi/python-libs /boot/python-libs
sudo overlayctl enable && sudo reboot
```

### B) Da immagine completa (dal Mac)

```bash
diskutil list                                   # trova la SD, es. disk6
diskutil unmountDisk /dev/disk6
sudo dd if="$HOME/Desktop/ogn-backup.img" of=/dev/rdisk6 bs=4m status=progress
diskutil eject /dev/disk6
```
Usa `"$HOME"` o il percorso completo (la tilde dopo `of=` non viene espansa sotto `sudo`). La SD nuova deve essere grande almeno quanto l'originale.

### Nodo Tailscale
Dopo la sostituzione rimuovi il vecchio nodo dalla console Tailscale: il nuovo può avere un IP diverso. Annotalo.

---

## 12. BACKUP

```bash
# solo /boot (consigliato) - dal Mac
rsync -rtv --no-perms --no-owner --no-group pi@<IP>:/boot/ ~/Desktop/ogn-boot-backup/

# immagine completa - dal Mac
diskutil list
diskutil unmountDisk /dev/disk6
sudo dd if=/dev/rdisk6 of="$HOME/Desktop/ogn-backup.img" bs=4m status=progress
diskutil eject /dev/disk6

# ridurre l'immagine (su Linux)
wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
chmod +x pishrink.sh
sudo ./pishrink.sh -a ogn-backup.img
```
Il backup di `/boot` contiene password e chiave Tailscale: tienilo fuori da GitHub.

---

## 13. COMANDI VARI

```bash
sudo reboot
cat /etc/os-release; uname -a
sudo rfkill block wifi            # spegne il WiFi (risparmio energia)
sudo screen /dev/ttyAMA0 115200   # SIM7080G: AT, AT+CPIN?, AT+CSQ, AT+CEREG?
```

### Verifica completa al mattino
```bash
date && timedatectl && sudo crontab -l && cat /tmp/setup_cron.log | tail -15 && sudo i2cget -y 1 0x68 0x0f
```

### Se il BMS blocca la batteria
Il RPi non risponde → problema hardware. Collega un alimentatore a ~12-13 V (limite 0.5 A) ai terminali del pacco/BMS (non al sistema) per sbloccarlo, poi ripristina il collegamento normale.

---

*Stazione OGN Solare - IU6SVB - Umbria/Toscana 1300 m s.l.m. - v1.7*
