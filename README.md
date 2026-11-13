# OGN Solar Receiver - ramo Raspberry Pi 3A+ (Bookworm, pacco 3S)

Questo ramo (`rpi-bookworm-3a-plus`) documenta la variante realizzata e provata sulla stazione **MCucco** a ottobre 2026. Il ramo `main` resta il progetto originale (Raspberry Pi 4, pacco 2S LiFePO4, relè) e non viene modificato.

Stazione ricevente OGN (Open Glider Network) autonoma: pannello solare, batteria, un microcontrollore che la accende ogni mattina e la spegne al tramonto.

## Cosa cambia rispetto a `main`

| | `main` | questo ramo |
|---|---|---|
| Raspberry Pi | Pi 4 (o Zero 2W), immagine OGN con overlay | **Pi 3A+**, Raspberry Pi OS Bookworm, rtlsdr-ogn 0.3.3, servizi systemd, nessun overlay |
| Pacco batterie | 2S LiFePO4 | **3S2P Li-ion 18650** con BMS (circa 6,4 Ah, stima) |
| Carica | - | modulo **CN3722** (MPPT) impostato 3S, pannello da 10 W |
| 5 V per la Pi | - | **Mini560** (ingresso 7-20 V) |
| Interruttore | relè | **MOSFET P** (AO3401 + BC547), PTC e TVS |
| Sketch ATtiny85 | v1.7.2 | **v1.7.3** (`SOGLIA_BATT_MIN 310`, `SOGLIA_BATT_ON 340`, partitore 56k/10k) |
| DS3231 | LIR2032 | **CR2032 senza ricarica** (togliere la resistenza di carica del modulo) |
| Partenza | 08:00 UTC | **10:00 ora locale** tutto l'anno |
| Sensori | INA219 | INA219 + **BME280** (temperatura e umidità della scatola) |

## Come funziona

- L'**ATtiny85** (Digispark) è sempre alimentato dal pacco. Ogni 30 s legge il DS3231 e la tensione del pacco; accende la Pi con il MOSFET dalle 10:00 locali e la scollega all'ora di taglio. Se la batteria scende sotto la soglia spegne, e riaccende solo sopra la soglia di riavvio (isteresi).
- **Partenza alle 10:00 locali:** il DS3231 contiene l'ora UTC più uno scarto (0 in ora legale, -1 in ora solare), quindi le "08:00" del DS3231 sono le 10:00 locali in ogni stagione. `ogn-boot-setup` scrive l'ora dopo la sincronizzazione NTP.
- **Spegnimento serale** (con `SCHEDULE=on`): `calc_sunset.py` calcola il tramonto e programma l'halt della Pi 90 minuti prima, il taglio dell'alimentazione 2 minuti dopo l'halt, con tetto alle 19:00 ora legale.
- **Orologio perso:** se il DS3231 ha perso l'ora, l'ATtiny alterna 2 ore acceso e 30 minuti spento, e la Pi riscrive l'ora al primo avvio.
- L'**INA219** (0x40) sta tra l'uscita del pacco e la Mini560: misura il consumo della stazione, non la carica.
- Un **secondo INA219** (0x41, ponticello A0) e' in serie sul positivo tra l'uscita del CN3722 (VIN+) e il pacco (VIN-): misura tensione, corrente e potenza di carica. Corrente positiva = entra nel pacco. Il cron scrive `/var/log/carica.csv` ogni 10 minuti e `stato` mostra l'energia in ingresso di oggi. Serve per dimensionare il pannello (10 W o 20 W).

## Soglie della batteria (valori misurati)

Sul Digispark il pin P4 (linea USB con zener da 3,6 V) carica il partitore: con 12,26 V sul pacco si misurano 1,72 V (rapporto 0,1403 invece di 0,1515) e VCC = 4,79 V. La formula è `V = conteggi / 1023 x VCC / rapporto`. Con 310 e 340 conteggi le soglie reali sono circa **10,35 V (spegnimento)** e **11,35 V (riavvio)**. La dispersione varia da un Digispark all'altro e con la temperatura; l'errore è dal lato sicuro. Va misurato sul proprio esemplare.

## Consumo e pannello

Misure fatte con l'INA219 sulla stazione 3A+ (valori medi dei campioni a 10 minuti):

| Situazione | Potenza |
|---|---|
| Pi + chiavetta RTL-SDR con `ogn-rf` attivo | circa **5,3 W** (30 ott 2026, 22 campioni) |
| Stessa stazione, chiavetta non rilevata | circa 3,9 W (31 ott 2026, 18 campioni) |

Stima (da confermare con i dati di giornate di sole): in estate la stazione resta accesa fino a 9 ore, cioè circa **50 Wh al giorno**. Un pannello da 10 W in Umbria rende circa 35-40 Wh al giorno tra giugno e luglio e meno nelle altre stagioni: **non basta con margine**. Per questo progetto è consigliato un pannello da **20 W** (controllare che la tensione a vuoto non superi il limite di ingresso del CN3722).

## Installazione

Guida completa: [`OGN-Comandi-SSH-3A-Bookworm.md`](OGN-Comandi-SSH-3A-Bookworm.md), sezione 0. In breve: Raspberry Pi OS Lite Bookworm 32 bit, rtlsdr-ogn 0.3.3 installato e funzionante (non lo fa lo script), poi:

```bash
curl -fsSLo install.sh "https://raw.githubusercontent.com/mapettar/OGN-Solar-Receiver/rpi-bookworm-3a-plus/src/rpi-bookworm/install.sh"
sudo bash install.sh --pacco 3s-liion --schedule on
sudo reboot
```

`install.sh` è stato provato il 31 ott 2026 su una **Raspberry Pi Zero 2 W con una SD nuova da 8 GB** (Bookworm, rtlsdr-ogn già installato) ed è andato a buon fine; sulla Pi 3A+ della stazione gli script sono stati messi a mano. Non installa rtlsdr-ogn, né Tailscale, e non scrive il nome del ricevitore o chiavi.

## Il comando `stato`

Ogni mattina, dopo l'avvio delle 10:00, il comando `stato` stampa un riepilogo con `[OK]` e `[!!]` e un verdetto: avvio all'ora giusta, orologio DS3231, spegnimento di ieri e avvio di oggi, servizi OGN, **chiavetta RTL-SDR, tentativi falliti e CPU di `ogn-rf`, rete verso il server APRS** (un `ogn-rf` in attesa non basta a dire che riceve), sottovoltaggi, batteria, carica (se c'è il secondo INA219), umidità della scatola, disco. Su una Pi di prova senza DS3231 e con `SCHEDULE=off` entra in **modalità banco di prova**: orologio, avvio e spegnimento diventano informativi e il verdetto riguarda solo chiavetta, servizi e rete.

### Riavvio automatico se la chiavetta manca (opzionale)

`ogn-usb-watchdog.sh` (cron ogni 5 minuti, `install.sh --watchdog prova|on`) interviene a gradini, dopo almeno due controlli consecutivi: se la chiavetta RTL-SDR manca da `lsusb` o `ogn-rf` non riesce ad aprirla, **riavvia la Pi**; se la chiavetta c'è ma `ogn-rf` è quasi inattivo (CPU sotto il 5%), **riavvia solo `rtlsdr-ogn` e `ogn-decode`** (3 volte al giorno, poi passa al riavvio della Pi). Limiti: 4 minuti dall'avvio (6 per il controllo della CPU), al massimo 2 riavvii della Pi al giorno (`WATCHDOG_MAX`), mai nei 45 minuti prima dello spegnimento serale. Con `WATCHDOG_USB=prova` in `/etc/default/ogn-boot-setup` scrive in `ogn-eventi.log` cosa farebbe senza riavviare. `stato` conta i riavvii di oggi. Non cura la causa (ancora sconosciuta): serve a non perdere il giorno.

**Blocco totale del sistema.** Il watchdog sopra gira da cron e quindi non può accorgersi di una Pi congelata del tutto (successo alla Zero 2 W il 9 nov 2026: ferma per ore, nessuna traccia perché il journal non era persistente). `install.sh --hw-watchdog on` abilita il watchdog hardware del chip (`RuntimeWatchdogSec=15` in `/etc/systemd/system.conf.d/ogn-watchdog.conf`): systemd lo alimenta e, se si ferma tutto, la Pi si riavvia da sola in circa 15 secondi. `install.sh` v1.6 rende anche persistente il journal (`Storage=persistent`, massimo 50 MB), così dopo un blocco `journalctl -b -1` mostra cosa è successo.

### Pagina di stato (opzionale)

Con `sudo bash install.sh --web on` il riepilogo di `stato` diventa anche una pagina HTML sulla porta **8090** (`stato_web.py` ogni 10 minuti, servita da `ogn-stato-web.service`, circa 10 MB di RAM). Si apre dalla rete locale o da Tailscale: **non aprire la porta sul router**. La pagina esiste solo con la Pi accesa e riporta l'ora dell'ultimo aggiornamento.

### Collegamento a internet via SIM (opzionale)

Dove manca il Wi-Fi la stazione usa una HAT **Waveshare SIM7080G** (LTE-M / NB-IoT, solo dati) con una SIM IoT (provata una SIM Simbase, APN `simbase`, che si registra in roaming su Vodafone IT in LTE-M, banda 3).

- **Hardware:** la HAT si alimenta dai 5 V della Pi e usa la seriale (`/dev/serial0` = `ttyAMA0`, GPIO14/15). Il connettore a 40 pin va **saldato** almeno sui pin 1-10: a pressione, senza saldatura, ha messo in corto SDA e SCL (12 nov 2026: DS3231, INA219 e BME280 non rispondevano; dopo la saldatura `i2cdetect` mostra di nuovo 40, 41, 57, 68, 76). Il ponticello **PWR-P7** collega il tasto PWRKEY a GPIO4; il ponticello 3,3 V-VCC lascia la logica a 3,3 V.
- **Accensione del modulo (verificata il 12-13 nov 2026):** il tasto PWRKEY si preme col pin **alto**: un impulso alto di 2 secondi accende o spegne il modulo (`SIM_PWR_ACTIVE=high`). All'avvio la Pi lascia GPIO4 in ingresso con la resistenza verso l'alto, quindi il tasto risulta premuto e **il modulo si accende da solo insieme alla Pi**: il servizio lo trova gia' acceso e registrato. L'impulso del servizio resta come riserva, e solo se il modulo non risponde ad AT (l'impulso inverte lo stato, quindi al massimo due per tentativo; dopo tre cicli falliti il modulo viene spento e riacceso). All'avvio il servizio riporta GPIO4 a riposo.
- **Servizio:** `sudo bash install.sh --sim auto` (oppure `always`) installa `ogn_sim.py`, `ogn-sim.service`, `/etc/default/ogn-sim` e i file di `pppd` (`/etc/ppp/chat-simbase`, `/etc/ppp/peers/simbase`). Con `auto` la SIM si usa solo se il Wi-Fi non da internet per 90 secondi (e si chiude dopo 300 secondi di Wi-Fi di nuovo buono); con `always` il PPP resta sempre su e il Wi-Fi, se c'e', passa avanti (metrica 700 contro 50 con Wi-Fi giu). `SIM_PLMN=22210` in `/etc/default/ogn-sim` fa scegliere a mano Vodafone IT (`AT+COPS=4`, con ritorno all'automatico): con la scelta automatica il modulo ripartito da zero restava a `CEREG 2` (cerca) per minuti, a mano si registra in pochi secondi.
- **`stato`** (v1.14) ha la sezione "SIM": modo, fase, indirizzo PPP, operatore, tecnologia, banda, RSRP (misurato alla registrazione, perche' con il PPP su la seriale e' occupata), riavvii, dati scambiati oggi. Eventi `sim ...` in `ogn-eventi.log`; byte scambiati in `/var/lib/ogn-sim/dati-AAAA-MM-GG`.
- **Strumento `sim_at.py`** (a servizio fermato, `sudo systemctl stop ogn-sim`): `sudo python3 sim_at.py` fa la diagnosi (SIM, radio, segnale, registrazione, operatore, bande), accetta comandi AT come argomenti, e con `--segnale [N]` fa N letture e la media di RSRP/RSRQ per confrontare antenne o posizioni.
- **Segnale (prove del 12-13 nov 2026, in casa):** con l'antenna migliore RSRP da -109 a -111 dBm, ping 190-230 ms, PPP stabile; con la peggiore -119/-120 dBm, registrazione lenta o assente e PPP che cade. Intorno a -116/-118 dBm il PPP sale ma cade ogni tanto (il servizio lo rialza da solo in 1-5 minuti). La posizione e il cavo dell'antenna contano quanto il modello.
- **Da verificare sul campo:** velocita' della seriale (ora 57600, il modulo la riconosce da solo; fissabile con `AT+IPR=115200` e `AT&W`), consumo del modulo in trasmissione, traffico quando la SIM e' l'unica strada (con il Wi-Fi davanti sono circa 0,5 MB all'ora tra controlli e Tailscale) e l'ora all'avvio: `ogn-boot-setup` aspetta NTP al massimo 180 secondi, e finche' l'ora non arriva (col PPP puo' essere dopo) gli eventi dell'avvio, compresi quelli `sim`, portano la data dell'ultimo spegnimento.

## Impostazioni consigliate della Pi

In `/boot/firmware/config.txt` (e `sudo systemctl disable --now bluetooth hciuart`): `dtparam=audio=off`, `dtoverlay=vc4-kms-v3d,nohdmi`, `dtoverlay=disable-bt`, `max_usb_current=1`. Con `disable-bt` la seriale PL011 passa sui pin GPIO14/15: se si collega un modulo (SIM7080G) va disattivata la console seriale. Per conservare i log dopo i riavvii: in `/etc/systemd/journald.conf` imposta `Storage=persistent` e `SystemMaxUse=50M` (sulla stazione MCucco c'era `Storage=volatile`, che annulla la cartella `/var/log/journal`), poi `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald`. Verifica con `journalctl --list-boots`.

## Problemi noti

- **Chiavetta RTL-SDR non rilevata** (31 ott 2026): dall'avvio delle 10:00 `lsusb` non la mostrava, `ogn-rf` ripeteva "Cannot open device" e la stazione non trasmetteva, mentre il vecchio controllo diceva "tutto ok". Alla riattaccatura comparivano errori USB `-71`. Un **riavvio con la chiavetta inserita direttamente** l'ha ripristinata. La causa non è stata identificata. Vedi la sezione 11 della guida SSH.
- **DS3231 che perde l'ora:** sulla millefori con LIR2032 la perdeva; sul PCB nuovo, con la ricarica tolta, tiene l'ora (prova di 27 minuti senza 5 V e prova notturna). Si consiglia la CR2032.
- **Digispark:** si programma solo da Windows, con il Digispark scollegato dal PCB e senza alimentazione sul PCB.

## Contenuto del ramo

| Percorso | Contenuto |
|---|---|
| `src/attiny/` | sketch del Digispark (v1.7.3 in uso) |
| `src/rpi-bookworm/` | script per la Pi 3A+: `install.sh`, `ogn-boot-setup.sh` e servizio, `calc_sunset.py`, `monitor_batteria.py`, `stato_stazione.sh`, `bme280_log.py`, `ds3231_log.sh` |
| `src/rpi-boot/` | script della versione originale (Pi 4) |
| `OGN-Comandi-SSH-3A-Bookworm.md` | guida rapida per la 3A+: installazione, verifica, ripristino |
| `OGN-Solar-Receiver-Documentazione_1.6.md` | documentazione del progetto originale |

**Chiavi e password non vanno mai in questo repository** (Tailscale, Wi-Fi, SSH): le immagini della SD contengono la configurazione della stazione e restano fuori da GitHub.

*Stazione OGN "MCucco" - IU6SVB - Umbria/Toscana, 1300 m s.l.m.*
