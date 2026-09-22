# Comandi SSH - Stazione OGN Solare
## Guida rapida verifica e controllo

**Connessione SSH:**
```
ssh pi@192.168.178.120
```

---

## 1. VERIFICA SISTEMA

### Ora e timezone
```bash
date                          # ora locale
date -u                       # ora UTC
timedatectl                   # stato timezone e NTP
```

### Spazio disco
```bash
df -h                         # spazio partizioni
lsblk                         # dimensione SD card
```

### Stato overlay filesystem
```bash
overlayctl status             # overlay attivo o no
```

---

## 2. VERIFICA DS3231 (RTC)

### Carica modulo I2C
```bash
sudo modprobe i2c-dev
```

### Verifica DS3231 presente sul bus
```bash
sudo i2cdetect -y 1           # deve mostrare 57 e 68
```

### Leggi ora attuale dal DS3231
```bash
sudo i2cget -y 1 0x68 0x02   # ore UTC (BCD)
sudo i2cget -y 1 0x68 0x01   # minuti (BCD)
sudo i2cget -y 1 0x68 0x00   # secondi (BCD)
```

### Leggi ora taglio rele dal registro allarme
```bash
sudo i2cget -y 1 0x68 0x09   # ore taglio rele (BCD)
sudo i2cget -y 1 0x68 0x08   # minuti taglio rele (BCD)
```

### Scrivi ora manualmente sul DS3231
```bash
# Sostituisci HH e MM con valori esadecimali BCD
# Esempio ore 10:30 UTC → 0x10 e 0x30
sudo i2cset -y 1 0x68 0x00 0x00    # secondi = 0
sudo i2cset -y 1 0x68 0x01 0x30    # minuti = 30
sudo i2cset -y 1 0x68 0x02 0x10    # ore = 10
```

### Conversione decimale → BCD (per i2cset)
```
ore 8  → 0x08    minuti 0  → 0x00
ore 9  → 0x09    minuti 5  → 0x05
ore 10 → 0x10    minuti 10 → 0x10
ore 11 → 0x11    minuti 15 → 0x15
ore 12 → 0x12    minuti 20 → 0x20
ore 13 → 0x13    minuti 30 → 0x30
ore 14 → 0x14    minuti 45 → 0x45
ore 15 → 0x15    minuti 50 → 0x50
ore 16 → 0x16    minuti 55 → 0x55
ore 17 → 0x17    minuti 59 → 0x59
```

---

## 3. VERIFICA CRONTAB E SHUTDOWN

### Mostra crontab attuale
```bash
sudo crontab -l
```

### Ricalcola tramonto e aggiorna crontab
```bash
sudo python3 /boot/calc_sunset.py
```

### Verifica stato servizio cron
```bash
sudo systemctl status cron
```

### Shutdown manuale immediato
```bash
sudo /sbin/shutdown -h now
```

---

## 4. VERIFICA NTP

### Sincronizzazione manuale NTP
```bash
sudo ntpdate -u pool.ntp.org
```

### Verifica sincronizzazione
```bash
timedatectl | grep synchronized
```

---

## 5. VERIFICA OGN RECEIVER

### Stato servizio OGN
```bash
sudo systemctl status ogn
```

### Log OGN in tempo reale
```bash
sudo journalctl -u ogn -f
```

### Verifica connessione glidernet
```bash
cat /tmp/glidernet-autossh.log
```

---

## 6. VERIFICA SETUP_CRON.SH

### Mostra contenuto script avvio
```bash
cat /boot/setup_cron.sh
```

### Esegui manualmente script avvio
```bash
sudo /boot/setup_cron.sh
```

### Mostra contenuto calc_sunset.py
```bash
cat /boot/calc_sunset.py
```

---

## 7. VERIFICA RETE

### Indirizzo IP
```bash
hostname -I
```

### Test connessione internet
```bash
ping -c 3 8.8.8.8
```

### Verifica interfacce di rete
```bash
ip addr show
```

---

## 8. VERIFICA BATTERIA (solo lettura ADC)

### Leggi valore ADC batteria su P4 ATtiny
Il valore ADC non è direttamente leggibile dal RPi.
Usa il multimetro sul pin P4 del Digispark.

### Tabella tensioni batteria LiFePO4 2S
```
Batteria    P4        ADC     Stato
6.6V    →  1.90V  →  381  →  Piena
6.3V    →  1.81V  →  363  →  Buona
6.0V    →  1.73V  →  347  →  Discreta
5.7V    →  1.64V  →  330  →  Minima accensione
5.4V    →  1.56V  →  310  →  Spegnimento sicuro
5.0V    →  1.44V  →  289  →  Pericolosa
```

---

## 9. FILE IMPORTANTI IN /boot

```bash
cat /boot/OGN-receiver.conf   # configurazione stazione
cat /boot/config.txt          # configurazione RPi
cat /boot/setup_cron.sh       # script avvio automatico
cat /boot/calc_sunset.py      # calcolo tramonto effemeridi
```

### Modifica file in /boot
```bash
sudo nano /boot/setup_cron.sh
sudo nano /boot/calc_sunset.py
sudo nano /boot/OGN-receiver.conf
```

---

## 10. COMANDI UTILI VARI

### Riavvio sistema
```bash
sudo reboot
```

### Storico log cron
```bash
sudo grep CRON /var/log/syslog | tail -20
```

### Processi attivi
```bash
ps aux | grep -E "ogn|ppp|autossh"
```

### Temperatura CPU
```bash
vcgencmd measure_temp
```

### Versione OS
```bash
cat /etc/os-release
uname -a
```

---

## 11. PROCEDURE COMUNI

### Dopo sostituzione batteria CR2032 DS3231
```bash
sudo modprobe i2c-dev
# Leggi ora sistema (deve essere corretta via NTP)
date -u
# Scrivi ora sul DS3231
H=$(date -u +%H); M=$(date -u +%M)
HH=$(printf '%02x' $((10#${H}/10*16 + 10#${H}%10)))
MM=$(printf '%02x' $((10#${M}/10*16 + 10#${M}%10)))
sudo i2cset -y 1 0x68 0x00 0x00
sudo i2cset -y 1 0x68 0x01 0x$MM
sudo i2cset -y 1 0x68 0x02 0x$HH
```

### Se BMS blocca la batteria
```bash
# Il RPi non risponde → problema hardware
# Collegare alimentatore 6.5-7.0V direttamente
# ai terminali batteria per sbloccare il BMS
# Poi ripristinare alimentazione normale
```

### Verifica completa al mattino
```bash
date && timedatectl && sudo crontab -l && sudo python3 /boot/calc_sunset.py
```

---

*Stazione OGN Solare - IU6SVB - Umbria/Toscana 1300m s.l.m.*
