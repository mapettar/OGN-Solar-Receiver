# Stazione OGN Solare Autonoma
## Guida completa alla costruzione e configurazione

**Versione:** 1.3  
**Data:** Settembre 2026  
**Basata su:** Esperienza pratica di installazione in montagna (Umbria/Toscana, 1300m s.l.m.)

---

## Indice

1. [Introduzione](#introduzione)
2. [Hardware necessario](#hardware-necessario)
3. [Schema elettrico](#schema-elettrico)
4. [Montaggio hardware](#montaggio-hardware)
5. [Sketch ATtiny85](#sketch-attiny85)
6. [Configurazione Raspberry Pi](#configurazione-raspberry-pi)
7. [Spegnimento dinamico tramite effemeridi](#spegnimento-dinamico-tramite-effemeridi)
8. [Configurazione SIM7080G](#configurazione-sim7080g)
9. [Installazione e test](#installazione-e-test)
10. [Troubleshooting](#troubleshooting)
11. [Bilancio energetico](#bilancio-energetico)
12. [Note finali](#note-finali)

---

## Introduzione

Questa guida descrive la realizzazione di una stazione ricevitore OGN (Open Glider Network) autonoma, alimentata da pannello solare e pacco batterie LiFePO4, installabile in zone remote senza rete elettrica ne WiFi.

Il sistema si accende automaticamente alle 10:00 (ora italiana) e si spegne dinamicamente in base al tramonto calcolato tramite effemeridi astronomiche, gestendo in modo intelligente l'alimentazione tramite un microcontrollore ATtiny85 che legge l'orario da un RTC DS3231 e controlla il livello di carica della batteria.

### Caratteristiche principali

- Accensione automatica alle 10:00 CEST tramite RTC DS3231
- Spegnimento dinamico basato su effemeridi (tramonto - 90 minuti)
- Controllo tensione batteria LiFePO4 2S con protezione scarica anticipata (prima del BMS)
- Filesystem in sola lettura (overlay) per protezione SD card
- Sincronizzazione NTP e DS3231 automatica ad ogni avvio via BSS138
- Connettivita mobile opzionale via SIM7080G HAT Waveshare
- Pannello solare 9W per ricarica giornaliera
- Diodo Schottky 1N5817 su VCC ATtiny per stabilita alimentazione

---

## Hardware necessario

### Componenti principali

| Componente | Specifiche | Note |
|------------|-----------|------|
| Raspberry Pi 4 | Model B, qualsiasi RAM | Con immagine OGN |
| ATtiny85 Digispark | Bootloader Micronucleus v1.6+ | Controller accensione |
| DS3231 RTC | Modulo ZS-042 blu | Con batteria CR2032 |
| Modulo rele | Con MOSFET integrato, HIGH trigger | Controllo alimentazione RPi |
| BSS138 | Modulo level shifter I2C 4 canali | Conversione 3.3V/5V tra RPi e DS3231/ATtiny |
| TPS63070 | Modulo DC/DC buck-boost | Stabilizzatore 5.1V output |
| Batteria LiFePO4 | 2S, 6Ah, con BMS | Tensione nominale 6.4V |
| Pannello solare | 18V, 9W | Per ricarica batteria |
| SIM7080G HAT | Waveshare, NB-IoT/Cat-M | Opzionale, per connettivita mobile |

### Componenti elettronici

| Componente | Valore | Utilizzo |
|------------|--------|----------|
| Resistenza R1 | 20 kOhm | Partitore tensione batteria (alta) |
| Resistenza R2 | 10 kOhm | Partitore tensione batteria (bassa) |
| Diodo D1 | 1N5817 Schottky | Su VCC ATtiny - stabilita alimentazione |
| Condensatore C1 | 100 uF elettrolitico | Stabilizzazione tensione rele |
| Resistenza pull-up SCL | 470 Ohm | Pull-up linea SCL su P3 |

---

## Schema elettrico

### Schema generale sistema

```
Pannello Solare 18V
        |
        +---- Regolatore di carica ---- Batteria LiFePO4 2S (6.4V)
        |                                        |
        |                              BMS (protezione celle)
        |                                        |
        +----------------------------------------+ TPS63070 DC/DC --> 5.1V
                                                 |
                          +----------------------+-----------------------+
                          |                      |                       |
                     ATtiny85               Modulo Rele            SIM7080G HAT
                     DS3231 RTC                  |                   (opzionale)
                     BSS138                      |
                                         Raspberry Pi 4
                                         (OGN Receiver)
```

### Schema ATtiny85 - Connessioni

```
ATtiny85 Digispark         Connessione
-----------------          ----------
P0 (SDA)          -------- SDA DS3231 (via BSS138 lato HV)
P1 (Rele)         -------- IN modulo rele (HIGH trigger)
P2                          NON USARE (problemi bootloader v1.6)
P3 (SCL)          -------- SCL DS3231 (via BSS138 lato HV) + pull-up 470 Ohm
P4 (ADC)          -------- Partitore tensione batteria
P5                          Reset (non usare)
5V                -------- Catodo D1 (1N5817) --> Anodo D1 --> 5.1V alimentazione
GND               -------- GND
```

### Diodo Schottky 1N5817 su VCC ATtiny85

Il diodo 1N5817 previene reset indesiderati quando il rele si attiva e il RPi assorbe corrente in avvio:

```
Alimentazione 5.1V --> Anodo 1N5817 --> Catodo 1N5817 --> VCC Digispark
```

### Schema BSS138 Level Shifter

```
BSS138 Level Shifter
--------------------
LV  (3.3V) -------- RPi 3.3V (GPIO pin 17)
HV  (5.0V) -------- 5.1V alimentazione
LV1        -------- RPi GPIO2 (SDA, pin 3)
LV2        -------- RPi GPIO3 (SCL, pin 5)
HV1        -------- SDA DS3231 + ATtiny P0
HV2        -------- SCL DS3231 + ATtiny P3
GND        -------- GND comune
```

### Schema partitore tensione batteria su P4

```
Batteria 6.4V
      |
     R1 20kOhm
      |
      +-------- P4 (A2) ATtiny85
      |
     R2 10kOhm
      |
     GND
```

### Soglie ADC batteria

Con partitore R1=20kOhm, R2=10kOhm, VCC=5.1V:

| Tensione batteria | Tensione P4 | Valore ADC | Stato |
|------------------|-------------|------------|-------|
| 6.6V | 1.90V | 381 | Piena |
| 6.0V | 1.73V | 347 | Buona |
| 5.7V | 1.64V | 330 | Minima accensione |
| 5.4V | 1.56V | 310 | Spegnimento sicuro |
| 5.0V | 1.44V | 289 | Zona pericolosa |
| 2.5V | 0.72V | 144 | BMS blocca tutto |

### Schema modulo rele HIGH trigger

```
ATtiny P1 ---- IN (segnale)
5.1V      ---- VCC
GND       ---- GND
Ponticello: posizione HIGH trigger

P1 LOW  = rele aperto  = RPi SPENTO (sicuro all'avvio ATtiny)
P1 HIGH = rele chiuso  = RPi ACCESO
```

---

## Montaggio hardware

### Passo 1 - Partitore tensione batteria

```
Batteria (+) --> R1 (20kOhm) --> nodo P4 --> R2 (10kOhm) --> GND
```

Il nodo tra R1 e R2 va collegato a P4 dell'ATtiny.

### Passo 2 - Diodo Schottky 1N5817 su VCC ATtiny

```
5.1V --> [Anodo 1N5817 | Catodo 1N5817] --> VCC Digispark
```

Previene i reset dell'ATtiny causati dai picchi di corrente all'avvio del RPi.

### Passo 3 - Pull-up SCL su P3

```
5V --[ 470 Ohm ]-- P3 (SCL)
```

### Passo 4 - Condensatore stabilizzazione

```
VCC Digispark --[ 100uF ]-- GND
```

### Passo 5 - BSS138 level shifter

- Lato LV: RPi GPIO2 (SDA) e GPIO3 (SCL) con alimentazione 3.3V
- Lato HV: DS3231 e ATtiny P0/P3 con alimentazione 5V
- GND comune tra tutti i moduli

Permette al RPi di sincronizzare l'ora sul DS3231 automaticamente ad ogni avvio.

---

## Sketch ATtiny85

### Libreria necessaria

SoftI2CMaster di Bernhard Nebel (Library Manager Arduino IDE)

### Impostazioni IDE

- Board: Digispark (Default - 16.5mhz)
- Programmer: Micronucleus

### Sketch definitivo v1.3

```cpp
#define SDA_PORT PORTB
#define SDA_PIN 0      // P0 = SDA
#define SCL_PORT PORTB
#define SCL_PIN 3      // P3 = SCL (NON usare P2 - problemi bootloader)

#include <SoftI2CMaster.h>

#define DS3231_ADDR      0x68
#define RELAY_PIN        1      // P1 = rele HIGH trigger
#define BATT_PIN         A2     // P4 = partitore batteria

// Orari in UTC (ora italiana CEST = UTC+2)
#define ORA_ACCENSIONE   8      // 8 UTC = 10:00 CEST
#define ORA_SPEGNIMENTO  20     // Failsafe ATtiny - il cron gestisce spegnimento reale

// Soglie ADC batteria
// Partitore R1=20k R2=10k, VCC=5.1V
// ADC = (Vbatt x 0.333 / 5.1) x 1023
#define SOGLIA_BATT_MIN  310    // ~5.4V spegne PRIMA che il BMS intervenga
#define SOGLIA_BATT_ON   330    // ~5.7V riaccende solo con batteria sufficientemente carica

bool statoRele = false;

uint8_t leggiRegistro(uint8_t reg) {
  i2c_start((DS3231_ADDR << 1) | I2C_WRITE);
  i2c_write(reg);
  i2c_stop();
  i2c_start((DS3231_ADDR << 1) | I2C_READ);
  uint8_t val = i2c_read(true);
  i2c_stop();
  return val;
}

uint8_t bcd2dec(uint8_t bcd) {
  return ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F);
}

uint8_t leggiOre() {
  return bcd2dec(leggiRegistro(0x02) & 0x3F);
}

int leggiADC() {
  long somma = 0;
  for (int i = 0; i < 5; i++) {
    somma += analogRead(BATT_PIN);
    delay(10);
  }
  return somma / 5;
}

void setup() {
  pinMode(RELAY_PIN, OUTPUT);
  pinMode(BATT_PIN, INPUT);

  // HIGH trigger: LOW = rele aperto = RPi spento (sicuro all'avvio)
  digitalWrite(RELAY_PIN, LOW);

  i2c_init();
  delay(500);

  uint8_t ore = leggiOre();
  int adcVal  = leggiADC();

  if (ore >= ORA_ACCENSIONE && ore < ORA_SPEGNIMENTO
      && adcVal >= SOGLIA_BATT_ON) {
    digitalWrite(RELAY_PIN, HIGH);
    statoRele = true;
  }
}

void loop() {
  uint8_t ore = leggiOre();
  int adcVal  = leggiADC();

  if (!statoRele) {
    // SPENTO: accendi se orario ok e batteria carica
    if (ore >= ORA_ACCENSIONE && ore < ORA_SPEGNIMENTO
        && adcVal >= SOGLIA_BATT_ON) {
      digitalWrite(RELAY_PIN, HIGH);
      statoRele = true;
    }
  } else {
    // ACCESO: spegni se:
    // 1. Failsafe orario ATtiny (20 UTC)
    // 2. Batteria sotto soglia sicura (5.4V)
    // NOTA: spegnimento serale normale gestito dal cron RPi via effemeridi
    // Le nuvole passeggere NON spengono la stazione
    if (ore < ORA_ACCENSIONE || ore >= ORA_SPEGNIMENTO
        || adcVal < SOGLIA_BATT_MIN) {
      digitalWrite(RELAY_PIN, LOW);
      statoRele = false;
    }
  }

  delay(30000); // controlla ogni 30 secondi
}
```

### Logica di funzionamento

```
ACCENSIONE (ogni mattina):
Ore 8 UTC (10:00 CEST) + batteria >= 5.7V --> RPi acceso

SPEGNIMENTO serale (gestito dal cron RPi):
Tramonto calcolato - 90 minuti --> shutdown pulito RPi
Failsafe 1 ora dopo --> secondo shutdown

FAILSAFE ATtiny (emergenza):
Ore 20 UTC (22:00 CEST) --> taglio alimentazione se cron fallisce

PROTEZIONE BATTERIA (priorita massima):
Batteria < 5.4V --> spegne subito indipendentemente dall'orario
Previene intervento BMS e freeze del sistema
```

---

## Configurazione Raspberry Pi

### Immagine OGN base

```
http://download.glidernet.org/seb-ogn-rpi-image
```

### Verifica espansione SD card

Dopo il primo avvio verificare che la SD sia stata espansa:

```bash
df -h
lsblk
```

Se la partizione root non occupa tutta la SD:

```bash
sudo raspi-config
# Advanced Options --> Expand Filesystem
sudo reboot
```

### File /boot/OGN-receiver.conf

```
### Mandatory ###
ReceiverName="TUONOME"
Latitude="43.349721"
Longitude="12.773177"

### Optional ###
EnableCoreOGNTeamRemoteAdmin="true"
piUserPassword="tuapassword"
runAtBoot="/boot/setup_cron.sh"
GSMCenterFreq="950"
OGNCenterFreq="868.3"
GSMGain="40"
Altitude="1300"
wifiName="TuaRete"
wifiPassword="TuaPassword"
wifiCountry="IT"
```

### File /boot/config.txt

```
dtparam=i2c_arm=on
# dtoverlay=i2c-rtc,ds3231  (commentato - conflitti con ATtiny)
enable_uart=1
```

### File /boot/calc_sunset.py

```python
#!/usr/bin/env python3
# Calcolo tramonto senza librerie esterne
# Modifica LAT, LON e MARGINE_MINUTI secondo le tue esigenze

import math
import datetime
import subprocess

# === CONFIGURAZIONE ===
LAT = 43.349721      # Latitudine stazione
LON = 12.773177      # Longitudine stazione
MARGINE_MINUTI = 90  # Minuti prima del tramonto per lo spegnimento

def calcola_tramonto(lat, lon, data=None):
    if data is None:
        data = datetime.date.today()
    N = data.timetuple().tm_yday
    lng_ora = lon / 15.0
    t = N + (18 - lng_ora) / 24
    M = (0.9856 * t) - 3.289
    L = M + (1.916 * math.sin(math.radians(M))) + \
        (0.020 * math.sin(math.radians(2 * M))) + 282.634
    L = L % 360
    RA = math.degrees(math.atan(0.91764 * math.tan(math.radians(L))))
    RA = RA % 360
    Lquadrant  = (math.floor(L  / 90)) * 90
    RAquadrant = (math.floor(RA / 90)) * 90
    RA = (RA + (Lquadrant - RAquadrant)) / 15
    sinDec = 0.39782 * math.sin(math.radians(L))
    cosDec = math.cos(math.asin(sinDec))
    cosH = (-0.01454) / (cosDec * math.cos(math.radians(lat)))
    if cosH > 1 or cosH < -1:
        return None
    H = math.degrees(math.acos(cosH)) / 15
    T = H + RA - (0.06571 * t) - 6.622
    UT = T - lng_ora
    return UT % 24

tramonto_utc = calcola_tramonto(LAT, LON)

if tramonto_utc:
    spegnimento_utc = tramonto_utc - (MARGINE_MINUTI / 60.0)
    if spegnimento_utc < 0:
        spegnimento_utc += 24
    ore   = int(spegnimento_utc)
    min_s = int((spegnimento_utc - ore) * 60)
    ore_fs = (ore + 1) % 24

    result = subprocess.run(
        ['crontab', '-u', 'root', '-l'],
        capture_output=True, text=True)
    linee = [l for l in result.stdout.split('\n')
             if l.strip() and 'shutdown' not in l]
    linee.append(f"{min_s} {ore} * * * /sbin/shutdown -h now")
    linee.append(f"0 {ore_fs} * * * /sbin/shutdown -h now")
    nuovo_cron = '\n'.join(linee) + '\n'
    subprocess.run(['crontab', '-u', 'root', '-'],
                   input=nuovo_cron, text=True)

    tramonto_h = int(tramonto_utc)
    tramonto_m = int((tramonto_utc - tramonto_h) * 60)
    print(f"Tramonto UTC:    {tramonto_h:02d}:{tramonto_m:02d}")
    print(f"Spegnimento UTC: {ore:02d}:{min_s:02d}")
    print(f"Failsafe UTC:    {ore_fs:02d}:00")
else:
    print("Errore calcolo tramonto - uso orario fisso")
    result = subprocess.run(
        ['crontab', '-u', 'root', '-l'],
        capture_output=True, text=True)
    linee = [l for l in result.stdout.split('\n')
             if l.strip() and 'shutdown' not in l]
    linee.append("55 17 * * * /sbin/shutdown -h now")
    linee.append("0 18 * * * /sbin/shutdown -h now")
    nuovo_cron = '\n'.join(linee) + '\n'
    subprocess.run(['crontab', '-u', 'root', '-'],
                   input=nuovo_cron, text=True)
```

### File /boot/setup_cron.sh

```bash
#!/bin/bash

# Forza timezone italiano
timedatectl set-timezone Europe/Rome

# Attendi rete disponibile
sleep 60
ntpdate -u pool.ntp.org

# Carica modulo I2C
modprobe i2c-dev

# Sincronizza DS3231 in UTC tramite i2cset
H=$(date -u +%H)
M=$(date -u +%M)
HH=$(printf '%02x' $((10#${H}/10*16 + 10#${H}%10)))
MM=$(printf '%02x' $((10#${M}/10*16 + 10#${M}%10)))
i2cset -y 1 0x68 0x00 0x00
i2cset -y 1 0x68 0x01 0x$MM
i2cset -y 1 0x68 0x02 0x$HH

# Installa pacchetti necessari (persi ad ogni reboot per overlay)
apt-get install -y screen minicom i2c-tools ppp > /dev/null 2>&1

# Calcola tramonto effemeridi e imposta crontab dinamico
python3 /boot/calc_sunset.py
```

Rendere eseguibile:
```bash
chmod +x /boot/setup_cron.sh
```

---

## Spegnimento dinamico tramite effemeridi

### Logica spegnimento

```
Ogni mattina al boot del RPi:
setup_cron.sh --> calc_sunset.py --> calcola tramonto del giorno
--> imposta crontab con orario dinamico

Spegnimento = tramonto - 90 minuti (configurabile)
Failsafe    = spegnimento + 60 minuti
```

### Esempi orari per posizione Umbria/Toscana (lat 43.35, lon 12.77)

| Periodo | Tramonto CEST | Spegnimento CEST | Failsafe CEST |
|---------|--------------|-----------------|---------------|
| Giugno | 21:00 | 19:30 | 20:30 |
| Settembre | 19:07 | 17:37 | 18:37 |
| Ottobre | 18:18 | 16:48 | 17:48 |
| Dicembre | 16:45 | 15:15 | 16:15 |

### Modificare il margine

In /boot/calc_sunset.py modificare:
```python
MARGINE_MINUTI = 90  # prima del tramonto
```

Valori positivi = prima del tramonto, negativi = dopo il tramonto.

---

## Configurazione SIM7080G

### Test connessione AT

```bash
sudo apt-get install -y screen
sudo screen /dev/ttyAMA0 115200
```

Comandi verifica:
```
AT              --> OK
AT+CPIN?        --> +CPIN: READY
AT+CIMI         --> IMSI (22210... = Vodafone IT)
AT+CSQ          --> qualita segnale (99,99 = nessun segnale)
AT+CEREG?       --> stato registrazione (0,1 = registrato)
```

### APN Vodafone NB-IoT

```
AT+CGDCONT=1,"IP","vo.vodafone.it"
AT+CFUN=1,1
```

---

## Installazione e test

### Verifica spazio SD card

```bash
df -h
lsblk
```

Se la partizione root non ha spazio sufficiente:
```bash
sudo raspi-config
# Advanced Options --> Expand Filesystem
sudo reboot
```

### Verifica sincronizzazione DS3231

```bash
sudo modprobe i2c-dev
sudo i2cget -y 1 0x68 0x02  # ore UTC
sudo i2cget -y 1 0x68 0x01  # minuti
date -u                      # confronta con sistema
```

### Verifica crontab dinamico

```bash
sudo crontab -l
sudo python3 /boot/calc_sunset.py
```

### Test ciclo giornaliero

```
Ore 10:00 CEST: ATtiny legge ora DS3231, rele chiude, RPi si accende
Al boot RPi: setup_cron.sh calcola tramonto e imposta crontab
Tramonto - 90min: cron esegue shutdown pulito RPi
Tramonto - 30min: failsafe cron
Ore 22:00 CEST: failsafe ATtiny taglia alimentazione
```

---

## Troubleshooting

### ATtiny non comunica con DS3231

- Verificare SDA su P0 e SCL su P3 (non P2!)
- Verificare pull-up 470 Ohm su P3
- Verificare alimentazione DS3231

### Rele oscilla all'avvio

- Verificare ponticello modulo rele su HIGH trigger
- Verificare diodo 1N5817 su VCC ATtiny
- Verificare condensatore 100uF

### Batteria si scarica e BMS blocca tutto

La batteria LiFePO4 con BMS entra in protezione a 2.5V/cella e si blocca.
Con le soglie corrette nello sketch ATtiny (SOGLIA_BATT_MIN=310, ~5.4V)
il sistema si spegne prima che il BMS intervenga.

Se il BMS si blocca:
```
Collegare alimentatore a 6.5V-7.0V direttamente ai
terminali batteria per sbloccare il BMS (non al sistema)
```

### DS3231 perde l'ora

- Sostituire batteria CR2032
- Verificare sincronizzazione via setup_cron.sh

### Spazio SD esaurito

Con overlay attivo lo spazio fisico non viene usato normalmente.
Se overlay e disabilitato verificare:
```bash
df -h
sudo raspi-config --> Advanced --> Expand Filesystem
```

---

## Bilancio energetico

| Componente | Corrente | Note |
|------------|---------|------|
| Raspberry Pi 4 | 270-360 mA | Media con SDR |
| Modulo rele | 20 mA | Solo quando attivo |
| ATtiny85 + DS3231 | 15 mA | Sempre attivo |
| SIM7080G idle | 39 mA | Se installato |
| Totale RPi acceso | ~360 mA | |
| Totale RPi spento | ~15 mA | Solo ATtiny |

Pannello 9W con 5h sole: ~7.5 Ah/giorno prodotti.
Consumo giornaliero: ~3.5 Ah.
Autonomia senza sole: ~1.3 giorni (batteria 6Ah).

---

## Note finali

### Fuso orario

Il DS3231 usa UTC. In estate (CEST = UTC+2):
- ORA_ACCENSIONE = 8 (10:00 CEST)

In inverno (CET = UTC+1) aggiornare sketch:
- ORA_ACCENSIONE = 9 (10:00 CET)

Lo spegnimento serale e gestito automaticamente dalle effemeridi
e si adatta alle stagioni senza modifiche.

### Protezione SD card

L'immagine OGN usa overlay filesystem - tutti i file sono in sola
lettura tranne /boot. Spegnimenti bruschi non danneggiano la SD.

### File persistenti in /boot

Unici file che sopravvivono al reboot:
- /boot/OGN-receiver.conf
- /boot/config.txt
- /boot/setup_cron.sh
- /boot/calc_sunset.py

### Risorse utili

- OGN Wiki: http://wiki.glidernet.org
- Immagine OGN: http://download.glidernet.org/seb-ogn-rpi-image
- Waveshare SIM7080G: https://www.waveshare.com/wiki/SIM7080G_Cat-M/NB-IoT_HAT
- SoftI2CMaster: https://github.com/felias-fogg/SoftI2CMaster

---

Documentazione basata su installazione reale in Umbria/Toscana, 1300m s.l.m.
Callsign operatore: IU6SVB - Versione 1.3 - Settembre 2026
