# Comandi SSH - Stazione OGN "MCucco" su Raspberry Pi 3A+ (Bookworm)
## Guida rapida verifica, controllo e ripristino (21 ott 2026)

Sostituisce `OGN-Comandi-SSH-Reference.md` (v1.7) per la 3A+: qui non c'è overlay, non ci sono script in `/boot`, i servizi sono systemd (`rtlsdr-ogn`, `ogn-decode`) e l'ora sul DS3231 la scrive `ogn-boot-setup`.

**Connessione** (accesso con chiave, senza password; non incollare mai password, chiavi o passphrase in chat o su GitHub):
```bash
ssh pi@ogn-pi3a                 # rete locale (192.168.178.161)
ssh pi@<IP-TAILSCALE>           # da remoto
ssh-keygen -R ogn-pi3a          # se la chiave host è cambiata (nuova SD)
```
Se il Mac richiede la passphrase a ogni accesso: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`.

> Dentro la Pi non digitare `ssh pi@ogn-pi3a`: ti collegheresti a te stesso. Il prompt `pi@ogn-pi3a:~ $` dice dove sei.

---

## 1. VERIFICA SISTEMA
```bash
date; date -u; uptime -p; uptime -s
timedatectl | grep synchronized          # yes = ora di sistema corretta
df -h /; vcgencmd measure_temp
cat /proc/net/wireless                    # segnale Wi-Fi (iw non è installato)
tail -8 /var/log/ogn-boot-setup.log       # esito dell'ultima scrittura dell'ora
tail -15 /boot/ogn-eventi.log             # spegnimenti e avvii (persistente)
```

## 2. SERVIZI OGN
```bash
systemctl status rtlsdr-ogn ogn-decode --no-pager | grep -E "Active|●"
sudo systemctl restart rtlsdr-ogn ogn-decode
ss -tn | grep -E "14580|50010"            # connessione APRS e ponte ogn-rf/decode
tail -2 ~/health.log                      # rf= e dec= devono valere 1 (cron ogni minuto)
journalctl -u ogn-decode -n 30 --no-pager
```
Pagine di stato: `http://ogn-pi3a:8082` (ogn-rf) e `http://ogn-pi3a:8083` (ogn-decode). Verifica su live.glidernet.org che **MCucco** sia online.
Il journal non è persistente: per conservarlo dopo i riavvii, `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald`.

## 3. DS3231 (orologio)
```bash
sudo i2cdetect -y 1                       # 40 = INA219, 57 = EEPROM del modulo, 68 = DS3231
for r in 0x02 0x01 0x00 0x0f; do sudo i2cget -y 1 0x68 $r; done    # ore, minuti, secondi (UTC, BCD), stato
```
Stato `0x80` (anche `0x8b`, `0x89`) = **orologio perso**: l'ATtiny accende il relè 2 h e lo spegne 30 min a cicli. `0x00`, `0x01`, `0x03` = valido (i bit bassi sono solo flag degli allarmi).

Scrivere l'ora vera (UTC) e azzerare il flag:
```bash
T=$(date -u +%H:%M:%S); b(){ printf "%02x" $(( $1/10*16 + $1%10 )); }; H=$((10#${T:0:2})); M=$((10#${T:3:2})); S=$((10#${T:6:2})); sudo i2cset -y 1 0x68 0x02 0x$(b $H); sudo i2cset -y 1 0x68 0x01 0x$(b $M); sudo i2cset -y 1 0x68 0x00 0x$(b $S); sudo i2cset -y 1 0x68 0x0f 0x00; echo "scritto $T UTC"
```
Oppure rilancia il servizio che lo fa da solo dopo la sincronizzazione (con `restart`, non `start`):
```bash
sudo systemctl restart ogn-boot-setup.service; tail -6 /var/log/ogn-boot-setup.log
```
**Attenzione alla finestra dell'ATtiny (UTC):** scrivere un'ora fuori da 08:00-17:00 UTC (10:00-19:00 italiane in ora legale, 09:00-18:00 da ora solare) fa aprire il relè entro 30 s e la Pi si spegne di colpo. Non usare `dtoverlay=i2c-rtc`: `i2cset` su 0x68 deve funzionare.

Se l'ora risulta indietro: il DS3231 non conta mentre manca il 5 V alla stazione. Verifica sempre la differenza con `date -u`.

## 4. SPEGNIMENTO SERALE (calc_sunset)
Programmazione attiva solo con `SCHEDULE=on`:
```bash
cat /etc/default/ogn-boot-setup
echo SCHEDULE=on | sudo tee /etc/default/ogn-boot-setup
sudo systemctl restart ogn-boot-setup.service       # ricalcola tramonto, crontab e taglio relè
sudo crontab -l | grep shutdown                     # 3 righe: halt (tramonto-90), failsafe, 17:00 UTC
sudo i2cget -y 1 0x68 0x09; sudo i2cget -y 1 0x68 0x08   # taglio relè: ore e minuti UTC (BCD)
```
L'halt deve cadere **2 minuti prima** del taglio. Per tornare indietro:
```bash
echo SCHEDULE=off | sudo tee /etc/default/ogn-boot-setup
sudo crontab -l | grep -v shutdown | sudo crontab -
```
Spegnimento a mano: `sudo shutdown -h now`. Con ATtiny v1.7.2, dopo un halt la Pi si può **riaccendere dopo circa 45 s** (l'ATtiny, leggendo il DS3231, tira giù SCL = GPIO3). La v1.7.3 smette di leggere negli ultimi 3 minuti prima del taglio.

## 5. BATTERIA (INA219)
```bash
python3 /usr/local/sbin/monitor_batteria.py                    # pacco 2S LiFePO4 (stazione attuale)
python3 /usr/local/sbin/monitor_batteria.py --pacco 3s-liion   # stazione con pacco 3S
python3 /usr/local/sbin/monitor_batteria.py --csv              # una riga: data,V,mA,W,stato
(crontab -l; echo '*/5 * * * * /usr/local/sbin/monitor_batteria.py --csv >> /home/pi/batteria.csv') | crontab -
```
L'ADC dell'ATtiny non è leggibile dalla Pi: misura con il tester sul pin P4 del Digispark.

Soglie dell'ATtiny (conteggio = V × rapporto ÷ VCC × 1023). Misure del 21 ott: partitore 10k/20k, P4 = 1,820 V con 6,45 V sul pacco (rapporto ≈ 0,282), VCC ATtiny = 4,6 V (diodo Schottky):

| | tensione | conteggi |
|---|---|---|
| attuali `SOGLIA_BATT_MIN` / `ON` | ≈ 4,9-5,0 V / 5,2-5,3 V | 310 / 330 |
| proposta (v1.7.4) spegni | 5,6 V | 350 |
| proposta (v1.7.4) riaccendi | 6,2 V | 388 |

Pacco 3S Li-ion (56k/10k): 310 / 340 corrispondono a ≈ 9,2 V / 10,1 V con VCC 4,6 V.

## 6. TAILSCALE
```bash
tailscale status; tailscale ip
```
Dopo una sostituzione della SD rimuovi il vecchio nodo dalla console Tailscale. Se una chiave di autenticazione è comparsa in una chat, **revocala** e generane una nuova. Le chiavi non vanno nei documenti né su GitHub.

## 7. SKETCH ATTINY (Digispark)
- Versione corrente: `src/attiny/OGN_Attiny_v1_7_3/OGN_Attiny_v1_7_3.ino` (Digispark Default 16.5 MHz, libreria SoftI2CMaster).
- **Da Windows** con il pacchetto "Digistump AVR Boards". Sul Mac Intel (macOS 13) il pacchetto Digispark non gira: il compilatore e lo strumento di caricamento sono a 32 bit, e ATTinyCore non si installa finché `drazzy.com` ha il certificato scaduto (`curl -sI https://drazzy.com/package_drazzy.com_index.json`).
- Carica con il Digispark **scollegato** e inseriscilo quando compare "Plug in device now".

## 8. BACKUP E RIPRISTINO IMMAGINE (dal Mac)
```bash
diskutil list                                 # trova la SD, es. disk6
diskutil unmountDisk /dev/disk6
sudo dd if=/dev/rdisk6 of="$HOME/ogn-3a-mcucco-$(date +%Y%m%d).img" bs=4m status=progress
sudo chmod 666 "$HOME"/ogn-3a-mcucco-*.img
diskutil eject /dev/disk6
```
Ridurre l'immagine: PiShrink in un contenitore Debian privilegiato (percorsi assoluti), poi `truncate -s <byte> file.img` **sul Mac**. L'immagine ridotta (≈ 4,75 GB) sta su una SD da 8 GB; la partizione si espande al primo avvio.
Scrittura su una SD nuova:
```bash
diskutil unmountDisk /dev/disk6
sudo dd if="$HOME/ogn-3a-mcucco-AAAAMMGG.img" of=/dev/rdisk6 bs=4m status=progress
diskutil eject /dev/disk6
```
Usa `"$HOME"` o il percorso completo (la tilde dopo `of=` non viene espansa sotto `sudo`). L'immagine contiene la configurazione della stazione: tienila fuori da GitHub.

## 9. DIFFERENZE RISPETTO ALLA STAZIONE VECCHIA
- Niente `overlayctl`, `setup_cron.sh`, `/boot/calc_sunset.py`: ora `ogn-boot-setup` in `/usr/local/sbin/` e `/etc/default/ogn-boot-setup`.
- `ntpdate` sostituito da `systemd-timesyncd` (`timedatectl | grep synchronized`).
- I tool I2C stanno in `/usr/sbin`: da `ssh pi@... '...'` usa `sudo`.
- Il firmware è in `/boot/firmware` (non in `/boot`).
- La vecchia Pi 4B (clone della SD vecchia) usa ancora l'overlay e **riscrive l'ora sul DS3231 a ogni avvio** se è collegata: non collegarla al DS3231 durante le prove. Un rinomina di file fatto con l'overlay attivo va perso al riavvio.

---
*Stazione OGN "MCucco" - IU6SVB - Umbria/Toscana 1300 m s.l.m. - Raspberry Pi 3A+ Bookworm*
