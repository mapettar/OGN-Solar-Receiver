# Sorgenti

| Percorso | Dove va | Note |
|----------|---------|------|
| `attiny/OGN_Attiny_v1_7_3/OGN_Attiny_v1_7_3.ino` | ATtiny85 Digispark (Arduino IDE) | Come la 1.7.2, ma negli ultimi 3 minuti prima del taglio non legge il DS3231 (SCL a massa sveglia la RPi in halt). Da usare con `SCHEDULE=on` (halt a tramonto-90, taglio a tramonto-88) |
| `attiny/OGN_Attiny_v1_7_2/OGN_Attiny_v1_7_2.ino` | ATtiny85 Digispark (Arduino IDE) | Soglie batteria per Li-ion 3S (R1 56k / R2 10k). Per LiFePO4 2S con partitore 20k/10k: `SOGLIA_BATT_MIN 310`, `SOGLIA_BATT_ON 330` |
| `rpi-boot/calc_sunset.py` | `/boot/` sulla RPi | Tramonto, crontab e taglio relè (tetto 19:00 CEST) |
| `rpi-boot/setup_cron.sh` | `/boot/` sulla RPi | Eseguito ad ogni avvio. Imposta `TS_AUTHKEY` con la TUA chiave Tailscale e **non pubblicarla** |
| `rpi-boot/monitor_batteria.py` | `/boot/` sulla RPi | Lettura INA219 |

Procedura di installazione e ripristino: vedi `OGN-Solar-Receiver-Documentazione_1.6.md` (versione 1.7) e `OGN-Comandi-SSH-Reference.md`.
