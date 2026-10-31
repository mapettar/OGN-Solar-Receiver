# Sorgenti

| Percorso | Dove va | Note |
|----------|---------|------|
| `attiny/OGN_Attiny_v1_7_3/OGN_Attiny_v1_7_3.ino` | ATtiny85 Digispark (Arduino IDE) | Come la 1.7.2, ma negli ultimi 3 minuti prima del taglio non legge il DS3231 (SCL a massa sveglia la RPi in halt). Da usare con `SCHEDULE=on` (halt a tramonto-90, taglio a tramonto-88) |
| `attiny/OGN_Attiny_v1_7_2/OGN_Attiny_v1_7_2.ino` | ATtiny85 Digispark (Arduino IDE) | Soglie batteria per Li-ion 3S (R1 56k / R2 10k). Per LiFePO4 2S con partitore 20k/10k: `SOGLIA_BATT_MIN 310`, `SOGLIA_BATT_ON 330` |
| `rpi-boot/calc_sunset.py` | `/boot/` sulla RPi | Tramonto, crontab e taglio relè (tetto 19:00 CEST) |
| `rpi-boot/setup_cron.sh` | `/boot/` sulla RPi | Eseguito ad ogni avvio. Imposta `TS_AUTHKEY` con la TUA chiave Tailscale e **non pubblicarla** |
| `rpi-boot/monitor_batteria.py` | `/boot/` sulla RPi | Lettura INA219 (pacco 3S, librerie Adafruit) |
| `rpi-bookworm/ogn-boot-setup.sh` + `.service` | `/usr/local/sbin/` e `/etc/systemd/system/` | Raspberry Pi 3A+ con Bookworm: scrive l'ora sul DS3231 dopo la sincronizzazione e (con `SCHEDULE=on` in `/etc/default/ogn-boot-setup`) imposta lo spegnimento serale |
| `rpi-bookworm/calc_sunset.py` | `/usr/local/sbin/` | Come `rpi-boot/calc_sunset.py` |
| `rpi-bookworm/monitor_batteria.py` | `/usr/local/sbin/` | Lettura INA219 senza librerie. Profili `2s-lifepo4` (default) e `3s-liion` con `--pacco`; `--csv` per i log |
| `rpi-bookworm/install.sh` | scaricato ed eseguito con `sudo` | Installa tutti gli script qui sotto, il comando `stato`, i cron e la rotazione dei log. Presuppone rtlsdr-ogn già funzionante. Provato solo a secco |
| `rpi-bookworm/stato_stazione.sh` (comando `stato`) | `/usr/local/sbin/` | Riepilogo mattutino con `[OK]`/`[!!]`: avvio, DS3231, ciclo spegnimento/avvio, servizi OGN, **chiavetta RTL-SDR e collegamento APRS**, alimentazione, batteria, BME280, disco (v1.4) |
| `rpi-bookworm/bme280_log.py` | `/usr/local/sbin/` | Temperatura, umidità, pressione e punto di rugiada della scatola in `/boot/bme280.log`; avviso in `ogn-eventi.log` a umidità ≥ 80 % |
| `rpi-bookworm/ds3231_log.sh` | `/usr/local/sbin/` | Una riga al minuto con ora e stato del DS3231 in `/var/log/ds3231.log` (cron) |

Soglie 3S: con il Digispark e il partitore 56k/10k, `SOGLIA_BATT_MIN 310` e `SOGLIA_BATT_ON 340` corrispondono a circa 10,35 V e 11,35 V (misurati; vedi `README.md` nella radice del ramo).

Procedura di installazione e ripristino per la Pi 3A+: `OGN-Comandi-SSH-3A-Bookworm.md`. Per il progetto originale (Pi 4): `OGN-Solar-Receiver-Documentazione_1.6.md` (versione 1.7) e `OGN-Comandi-SSH-Reference.md`.
