# Comandi SSH - Stazione OGN "MCucco" su Raspberry Pi 3A+ (Bookworm)
## Guida rapida verifica, controllo e ripristino (aggiornata il 31 ott 2026)

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

## 0. INSTALLAZIONE DA ZERO IN UN COMANDO (nuova stazione)
**Prima, l'immagine adatta alla Pi 3A+:**
1. Con *Raspberry Pi Imager* scrivi sulla SD **Raspberry Pi OS Lite, Bookworm, 32 bit** (rtlsdr-ogn 0.3.3 richiede 32 bit). Nelle impostazioni dell'Imager: nome della stazione (hostname), utente `pi`, **SSH con chiave** (non password), Wi-Fi, fuso orario Europe/Rome.
2. Avvia la Pi, collegati via SSH e installa **rtlsdr-ogn 0.3.3** con il nome della stazione (`ReceiverName`) e i servizi `rtlsdr-ogn` e `ogn-decode`. Questo passaggio non fa parte dell'installatore.

**Poi, un comando** (scarica, leggi se vuoi, lancia):
```bash
curl -fsSLo install.sh "https://raw.githubusercontent.com/mapettar/OGN-Solar-Receiver/rpi-bookworm-3a-plus/src/rpi-bookworm/install.sh"
sudo bash install.sh --pacco 3s-liion --schedule on
sudo reboot
```
- `--pacco 3s-liion` (default) o `2s-lifepo4`: profilo batteria per il comando `stato` e per `monitor_batteria`.
- `--schedule on`: spegnimento serale al tramonto. Usalo solo con ATtiny v1.7.3 e DS3231 collegati; **senza** (`off`, default) la Pi non si spegne da sola.
- Installa gli script in `/usr/local/sbin/`, il servizio `ogn-boot-setup`, il comando `stato`, i log del DS3231, del BME280 e della batteria (cron in `/etc/cron.d/ogn-station`) e la rotazione dei log. Attiva I2C. Si può rilanciare: i file diversi vengono salvati come `.bak-AAAAMMGG-HHMM`.
- **Non** installa OGN, non configura Wi-Fi e non tocca Tailscale: le chiavi restano a mano.
- Dopo il riavvio, 3-4 minuti dopo: `stato` (riepilogo con verdetto).

---

## 1. VERIFICA SISTEMA
Il primo comando di ogni mattina (dopo le 10:00 locali) è `stato`: un riepilogo con `[OK]` e `[!!]` e il verdetto finale (vedi la sezione 12). I comandi qui sotto servono per approfondire.
```bash
stato
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
sudo i2cdetect -y 1                       # 40 = INA219, 41 = secondo INA219 (se montato), 57 = EEPROM del modulo, 68 = DS3231, 76 = BME280
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

Soglie dell'ATtiny (conteggio = V × rapporto ÷ VCC × 1023). **Tabella della vecchia stazione 2S (smontata il 29 ott 2026)**, misure del 21 ott: partitore 10k/20k, P4 = 1,820 V con 6,45 V sul pacco (rapporto ≈ 0,282), VCC ATtiny = 4,6 V (diodo Schottky):

| | tensione | conteggi |
|---|---|---|
| attuali `SOGLIA_BATT_MIN` / `ON` | ≈ 4,9-5,0 V / 5,2-5,3 V | 310 / 330 |
| proposta (v1.7.4) spegni | 5,6 V | 350 |
| proposta (v1.7.4) riaccendi | 6,2 V | 388 |

**Pacco 3S Li-ion (56k/10k), valori misurati il 30 ott 2026:** il pin P4 del Digispark (linea USB con zener) carica il partitore. Con 12,26 V sul pacco, P4 = 1,72 V (rapporto 0,1403, non 0,1515) e VCC = 4,79 V. Le soglie 310 / 340 corrispondono quindi a ≈ **10,35 V (spegnimento) / 11,35 V (riavvio)**. Un partitore 18k/3,3k, provato per alzare il rapporto, ha dato 1,55 V (sotto la soglia di riavvio) con quel Digispark ed è stato rimesso a 56k/10k. La dispersione varia da un Digispark all'altro: misura P4 sul tuo e ricalcola con la formula.

Per misurare anche la **carica** serve un secondo INA219, in serie sul positivo tra l'uscita del CN3722 e il pacco (VIN+ lato CN3722, VIN− lato pacco). Il suo indirizzo deve essere 0x41: si unisce con una goccia di stagno il ponticello **A0**. Il primo INA219 (0x40) misura solo il consumo, perché sta tra il pacco e la Mini560.

Lettura a mano del secondo INA219 (corrente positiva = entra nel pacco, tensione = lato pacco):
```bash
sudo python3 /usr/local/sbin/monitor_batteria.py --addr 0x41 --carica
```
Con `install.sh` v1.3 il cron scrive una riga ogni 10 minuti in `/var/log/carica.csv` (`data,V,mA,W`) e `stato` mostra la sezione **Carica** con l'energia in ingresso di oggi. Tra VIN+ e VIN− si misurano alcune decine di mV solo mentre carica (0,1 Ω di shunt: 90 mV ≈ 0,9 A); a carica ferma le due tensioni sono uguali. Dopo lo spegnimento serale la Pi non registra, quindi l'energia in ingresso reale è maggiore di quella mostrata.

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
- La Pi 4B di prova, con la SD clonata della stazione vecchia, è stata smontata il 29 ott 2026. Se una Pi con quella SD (overlay attivo) viene ricollegata, **riscrive l'ora sul DS3231 a ogni avvio**: non collegarla al DS3231 durante le prove. Un file rinominato con l'overlay attivo va perso al riavvio.

## 10. IMPOSTAZIONI CONSIGLIATE DELLA PI (radio inutili spente)
Su una stazione senza schermo né audio si spengono Bluetooth, HDMI e audio: meno radio vicino al ricevitore e qualche decimo di watt in meno (stima 0,15-0,3 W). Prima fai la copia di sicurezza di `config.txt`:
```bash
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak-$(date +%Y%m%d)
grep -nE '^\[|vc4|disable-bt|dtparam=audio|hdmi' /boot/firmware/config.txt     # controlla le sezioni
sudo sed -i 's/^dtparam=audio=on/dtparam=audio=off/' /boot/firmware/config.txt
sudo sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,nohdmi/' /boot/firmware/config.txt
printf '\ndtoverlay=disable-bt\n' | sudo tee -a /boot/firmware/config.txt
sudo systemctl disable --now bluetooth hciuart
sudo reboot
```
Il `printf` parte da una riga vuota perché l'ultima riga del file potrebbe non finire con un a capo. Le righe vanno nell'ultima sezione (`[all]`): controlla con il `grep`. Dopo il riavvio `rfkill list` deve mostrare solo il Wi-Fi e `lsusb` ancora la RTL2838. Se la Pi non torna in rete, rimetti `config.txt` dal backup (partizione FAT della SD).

Nel `config.txt` standard `otg_mode=1` (`[cm4]`) e `dtoverlay=dwc2` (`[cm5]`) non valgono per la 3A+; `max_usb_current=1` sotto `[all]` sì.

Con `disable-bt` la seriale PL011 passa sui pin GPIO14/15: collegando un modulo seriale (SIM7080G) va tolta la console seriale (`console=serial0,115200` in `/boot/firmware/cmdline.txt`).

## 11. CHIAVETTA RTL-SDR NON RILEVATA
Sintomo (31 ott 2026): la Pi parte all'ora giusta ma la stazione risulta spenta su KTrax e su live.glidernet.org; `lsusb` mostra solo l'hub (`1d6b:0002`), `ogn-rf` ripete `Cannot open device #0 ... retry after 10 sec` e i consumi sono più bassi del solito (circa 3,9 W invece di 5,3 W). I servizi risultano "running" anche così.
```bash
lsusb                                                        # deve comparire 0bda:2838 (RTL2838)
dmesg | grep -iE 'usb 1-1|error -71|EMI' | tail -20          # errori USB dall'avvio
journalctl -b -u rtlsdr-ogn --no-pager | grep -c 'Cannot open device'
vcgencmd get_throttled                                       # 0x0 = nessun sottovoltaggio
```
Se la rete di casa va giù (blackout o router spento) la stazione continua a ricevere ma non può inviare: su KTrax compare ferma. Per distinguere, guarda `batteria.csv` (consumo ~5 W anche dopo l'ora in cui KTrax si ferma) e il giornale del servizio `ogn-decode`.

Cosa significano gli errori: `error -71` e `disabled by hub (EMI?)` sono errori di comunicazione sul cavo (contatto, cavo, alimentazione della porta o disturbo). Nessuna riga USB all'avvio = la porta non vede nulla.

Cosa fare, in ordine:
1. Riattacca la chiavetta **direttamente alla porta**, senza cavo né adattatore.
2. Se non compare, **riavvia con la chiavetta già inserita**: `sudo reboot`. Dopo un errore ripetuto il controller USB della 3A+ può restare bloccato (la porta non si può spegnere via software) e solo il riavvio lo ripulisce. Il 31 ott 2026 è bastato questo.
3. Se gli errori `-71` tornano, prova un'altra chiavetta (le NESDR hanno tutte il numero di serie `00000001`: non collegarne due insieme) e un cavo diverso; misura i 5 V ai test point TP1/TP2 sul retro della Pi con la chiavetta inserita.
4. La chiavetta si può provare su un PC: `Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0BDA' }` in PowerShell deve mostrarla con `Status: OK`.

Causa del caso del 31 ott: **non identificata**. Il comando `stato` (v1.5) controlla ora chiavetta, errori USB e collegamento al server, per accorgersene al mattino; per ricostruire cosa è successo nei giorni precedenti serve il journal persistente (sezione 2).

## 12. IL COMANDO `stato`
```bash
stato          # equivale a: sudo bash /usr/local/sbin/stato_stazione.sh
```
Legge soltanto, non modifica niente. Sezioni e cosa fare con un `[!!]`:

| Sezione | Controlla | Se c'è un `[!!]` |
|---|---|---|
| Avvio | accensione alle 10:00 locali (o 08:00 UTC) | un riavvio manuale lo fa comparire: è atteso. Altrimenti: ora del DS3231 persa o ATtiny in recupero |
| Orologio DS3231 | flag OSF, differenza dall'ora UTC, prima lettura del giorno (se fallita non si può dire se l'ora c'era), NTP | OSF acceso = l'ora si è persa; controlla la CR2032 e la sezione 3. Senza DS3231 (prove su altra Pi) è normale |
| Ciclo spegnimento / avvio | spegnimento di ieri e avvio di oggi in `ogn-eventi.log` | taglio brusco dell'ATtiny: controlla batteria e soglie |
| Servizi OGN | processi `ogn-rf` e `ogn-decode` | `sudo systemctl restart rtlsdr-ogn ogn-decode` |
| Ricevitore | chiavetta in `lsusb`, errori USB nel kernel, tentativi falliti di `ogn-rf` (**in corso** oppure **episodio concluso** con l'ora dell'ultimo), CPU di `ogn-rf` sul momento (misurata sulla Zero 2W: da 40% a oltre 100% quando lavora; sotto 15% è sospetto), rete verso il server APRS (dice solo che la rete c'è, non che si riceve) | sezione 11 |
| Alimentazione e temperatura | `get_throttled` (sottovoltaggio, limitazioni) | alimentazione della Pi: cavi, Mini560 |
| Batteria | INA219: tensione, corrente, potenza, giudizio | pacco scarico: controlla pannello e carica |
| Carica (secondo INA219) | tensione lato pacco, corrente e potenza di carica, energia in ingresso e consumo di oggi | corrente negativa = INA219 montato al contrario; nessun dato = cron non attivo o INA219 non montato |
| Scatola (BME280) | temperatura, umidità, margine dal punto di rugiada | umidità ≥ 80 % o margine < 3 °C: rischio condensa |
| Disco | uso della SD | spazio quasi pieno |

---
*Stazione OGN "MCucco" - IU6SVB - Umbria/Toscana 1300 m s.l.m. - Raspberry Pi 3A+ Bookworm*
