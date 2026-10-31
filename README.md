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

`install.sh` **non è ancora stato provato su una SD nuova**: è stato verificato solo a secco (`--no-system`). Non installa Tailscale e non scrive ReceiverName o chiavi.

## Il comando `stato`

Ogni mattina, dopo l'avvio delle 10:00, il comando `stato` stampa un riepilogo con `[OK]` e `[!!]` e un verdetto: avvio all'ora giusta, orologio DS3231, spegnimento di ieri e avvio di oggi, servizi OGN, **chiavetta RTL-SDR e collegamento al server APRS** (un `ogn-rf` in attesa non basta a dire che riceve), sottovoltaggi, batteria, umidità della scatola, disco.

## Impostazioni consigliate della Pi

In `/boot/firmware/config.txt` (e `sudo systemctl disable --now bluetooth hciuart`): `dtparam=audio=off`, `dtoverlay=vc4-kms-v3d,nohdmi`, `dtoverlay=disable-bt`, `max_usb_current=1`. Con `disable-bt` la seriale PL011 passa sui pin GPIO14/15: se si collega un modulo (SIM7080G) va disattivata la console seriale. Per conservare i log del kernel e dei servizi dopo i riavvii: `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald`.

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
