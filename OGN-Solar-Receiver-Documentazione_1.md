# Stazione OGN Solare Autonoma
## Guida completa alla costruzione e configurazione

**Versione:** 1.0  
**Data:** Agosto 2026  
**Basata su:** Esperienza pratica di installazione in montagna (Umbria/Toscana, 1300m s.l.m.)

---

## Indice

1. [Introduzione](#introduzione)
2. [Hardware necessario](#hardware-necessario)
3. [Schema elettrico](#schema-elettrico)
4. [Montaggio hardware](#montaggio-hardware)
5. [Sketch ATtiny85](#sketch-attiny85)
6. [Configurazione Raspberry Pi](#configurazione-raspberry-pi)
7. [Configurazione SIM7080G](#configurazione-sim7080g)
8. [Installazione e test](#installazione-e-test)
9. [Troubleshooting](#troubleshooting)
10. [Note finali](#note-finali)

---

## Introduzione

Questa guida descrive la realizzazione di una stazione ricevitore OGN (Open Glider Network) autonoma, alimentata da pannello solare e pacco batterie LiFePO4, installabile in zone remote senza rete elettrica né WiFi.

Il sistema si accende automaticamente alle 10:00 e si spegne alle 19:00 (ora italiana estiva CEST), gestendo in modo intelligente l'alimentazione tramite un microcontrollore ATtiny85 che legge l'orario da un RTC DS3231 e controlla il livello di carica della batteria.

### Caratteristiche principali

- Accensione/spegnimento automatico tramite RTC DS3231
- Controllo tensione batteria LiFePO4 2S
- Protezione da scarica eccessiva della batteria
- Filesystem in sola lettura (overlay) per protezione SD card
- Sincronizzazione NTP automatica ad ogni avvio
- Sincronizzazione orario DS3231 automatica via RPi
- Connettività mobile opzionale via SIM7080G HAT
- Pannello solare 9W per ricarica giornaliera

---

## Hardware necessario

### Componenti principali

| Componente | Specifiche | Note |
|------------|-----------|------|
| Raspberry Pi 4 | Model B, qualsiasi RAM | Con immagine OGN |
| ATtiny85 Digispark | Bootloader Micronucleus v1.6+ | Controller accensione |
| DS3231 RTC | Modulo ZS-042 blu | Con batteria CR2032 |
| Modulo relè | Con MOSFET integrato, HIGH trigger | Controllo alimentazione RPi |
| BSS138 | Modulo level shifter I2C 4 canali | Conversione 3.3V/5V |
| TPS63070 | Modulo DC/DC buck-boost | Stabilizzatore 5.1V |
| Batteria LiFePO4 | 2S, 6Ah, con BMS | Tensione nominale 6.4V |
| Pannello solare | 18V, 9W | Per ricarica batteria |
| SIM7080G HAT | Waveshare, NB-IoT/Cat-M | Opzionale, per connettività mobile |

### Componenti elettronici

| Componente | Valore | Utilizzo |
|------------|--------|----------|
| Resistenza R1 | 20 kΩ | Partitore tensione batteria (alta) |
| Resistenza R2 | 10 kΩ | Partitore tensione batteria (bassa) |
| Diodo D1 | 1N5817 (Schottky) | Protezione reset ATtiny su VCC |
| Condensatore C1 | 100 µF elettrolitico | Stabilizzazione tensione relè |
| Resistenza pull-up SCL | 470 Ω - 1 kΩ | Pull-up linea SCL su P3 |

---

## Schema elettrico

### Schema generale sistema

```
Pannello Solare 18V
        │
        ├──── Regolatore di carica ──── Batteria LiFePO4 2S (6.4V)
        │                                        │
        │                              BMS (protezione celle)
        │                                        │
        └────────────────────────────── TPS63070 DC/DC ──── 5.1V
                                                 │
                          ┌──────────────────────┼──────────────────────┐
                          │                      │                      │
                     ATtiny85               Modulo Relè            SIM7080G HAT
                     DS3231 RTC                  │                  (opzionale)
                     BSS138                      │
                                         Raspberry Pi 4
                                         (OGN Receiver)
```

### Schema ATtiny85 - Connessioni

```
ATtiny85 Digispark         Connessione
─────────────────          ──────────
P0 (SDA)          ──────── SDA DS3231 (via BSS138 lato HV)
P1 (Relè)         ──────── IN modulo relè (HIGH trigger)
P2                          NON USARE (problemi bootloader)
P3 (SCL)          ──────── SCL DS3231 (via BSS138 lato HV) + pull-up
P4 (ADC)          ──────── Partitore tensione batteria/pannello
P5                          Reset (non usare)
5V                ──────── VCC
GND               ──────── GND
```

### Schema BSS138 Level Shifter

```
BSS138 Level Shifter
────────────────────
LV  (3.3V) ──────── RPi 3.3V (GPIO pin 17)
HV  (5.0V) ──────── 5.1V alimentazione
LV1        ──────── RPi GPIO2 (SDA, pin 3)
LV2        ──────── RPi GPIO3 (SCL, pin 5)
HV1        ──────── SDA DS3231 + ATtiny P0
HV2        ──────── SCL DS3231 + ATtiny P3
GND        ──────── GND comune
```

### Schema partitore tensione su P4

```
Batteria 6.4V
      │
     R1 20kΩ
      │
      ├──── P4 (A2) ATtiny85
      │
     R2 10kΩ
      │
     GND
```

### Schema diodo 1N5817 su VCC ATtiny85

Il diodo Schottky 1N5817 sull'alimentazione dell'ATtiny evita che il picco
di corrente all'attivazione del relè resetti il microcontrollore:

```
5.1V ──── Anodo D1 (1N5817) ──── Catodo D1 ──── VCC ATtiny85
                                                       │
                                               C1 100µF
                                                       │
                                                      GND
```

La caduta di tensione del diodo Schottky è solo ~0.3V, quindi l'ATtiny
riceve circa 4.8V — sufficiente per operare correttamente a 5V nominali.

### Schema modulo relè HIGH trigger

```
ATtiny P1 ──── IN (segnale)
5.1V      ──── VCC
GND       ──── GND
Ponticello: posizione HIGH trigger

NO  ──── Alimentazione 5.1V input
COM ──── Alimentazione 5.1V output → TPS63070 → RPi
NC       (non collegato)

P1 LOW  = relè aperto  = RPi SPENTO
P1 HIGH = relè chiuso  = RPi ACCESO
```

---

## Montaggio hardware

### Passo 1 — Partitore tensione batteria

Collega le resistenze in serie tra il positivo della batteria e GND, con il punto di prelievo tra R1 e R2 che va a P4 dell'ATtiny:

```
Batteria (+) → R1 (20kΩ) → nodo P4 → R2 (10kΩ) → GND
```

La tensione su P4 con batteria a 6.6V sarà circa 1.8V, compatibile con l'ADC dell'ATtiny a 5V.

### Passo 2 — Diodo 1N5817 su VCC ATtiny85

Questo è un componente critico — risolve il problema del reset dell'ATtiny
quando il relè si attiva e il Raspberry Pi assorbe il picco di corrente iniziale.

Collega il diodo Schottky 1N5817 in serie tra l'alimentazione 5V e il pin VCC
del Digispark:

```
5.1V ──── Anodo 1N5817 ──── Catodo 1N5817 ──── VCC Digispark
```

Orientamento: la fascia argentata sul diodo va verso il Digispark (catodo).
La caduta di tensione Schottky è solo ~0.3V — l'ATtiny funziona correttamente.

### Passo 3 — Pull-up SCL su P3

Aggiungi una resistenza da 470Ω tra P3 e 5V per garantire corretta comunicazione I2C:

```
5V ──┤470Ω├── P3 (SCL)
```

### Passo 4 — Condensatore stabilizzazione

Collega un condensatore 100µF direttamente sui pin VCC e GND del Digispark
(dopo il diodo 1N5817) per stabilizzare ulteriormente la tensione:

```
VCC Digispark ──┤100µF├── GND
```

### Passo 5 — BSS138 collegamento

Segui lo schema BSS138 per collegare RPi (3.3V) al DS3231 e ATtiny (5V):

- Lato LV: collega a RPi GPIO2 (SDA) e GPIO3 (SCL) con alimentazione 3.3V
- Lato HV: collega a DS3231 e ATtiny P0/P3 con alimentazione 5V
- GND comune tra tutti i moduli

---

## Sketch ATtiny85

Questo sketch gestisce l'accensione e lo spegnimento del Raspberry Pi in base all'orario letto dal DS3231 e al livello di carica della batteria.

### Sketch definitivo

```cpp
#define SDA_PORT PORTB
#define SDA_PIN 0      // P0 = SDA
#define SCL_PORT PORTB
#define SCL_PIN 3      // P3 = SCL

#include <SoftI2CMaster.h>

#define DS3231_ADDR      0x68
#define RELAY_PIN        1      // P1 = relè HIGH trigger
#define BATT_PIN         A2     // P4 = partitore batteria

// Orari in UTC (ora italiana CEST = UTC+2)
#define ORA_ACCENSIONE   8      // 8 UTC = 10:00 CEST
#define ORA_SPEGNIMENTO  17     // 17 UTC = 19:00 CEST

// Soglie ADC batteria (ADC su 1023, VCC = 5.1V)
#define SOGLIA_BATT_MIN  270    // ~4.7V protezione scarica assoluta
#define SOGLIA_BATT_ON   280    // ~5.0V tensione minima per accendere

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

  // HIGH trigger: LOW = relè aperto = RPi spento (sicuro all'avvio)
  digitalWrite(RELAY_PIN, LOW);

  i2c_init();
  delay(500);

  uint8_t ore = leggiOre();
  int adcVal  = leggiADC();

  // Accendi se orario corretto e batteria sufficientemente carica
  if (ore >= ORA_ACCENSIONE && ore < ORA_SPEGNIMENTO
      && adcVal >= SOGLIA_BATT_ON) {
    digitalWrite(RELAY_PIN, HIGH); // relè chiuso = RPi acceso
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
    // ACCESO: spegni SOLO se orario finito o batteria scarica
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

### Libreria necessaria

Nel Library Manager di Arduino IDE cerca e installa:
- **SoftI2CMaster** di Bernhard Nebel (aka Felias Fogg)

### Impostazioni IDE Arduino per ATtiny85 Digispark

- Board: Digispark (Default - 16.5mhz)
- Programmer: Micronucleus

---

## Configurazione Raspberry Pi

### Immagine OGN base

Scarica e flasha l'immagine OGN ufficiale:
```
http://download.glidernet.org/seb-ogn-rpi-image
```

Usa Raspberry Pi Imager o Balena Etcher per flashare sulla SD card.

### File /boot/OGN-receiver.conf

Configura i parametri della stazione:

```bash
### Mandatory ###
ReceiverName="TUONOME"        # Nome stazione (segui convenzione OGN)
Latitude="43.349721"          # Latitudine decimale
Longitude="12.773177"         # Longitudine decimale

### Optional ###
EnableCoreOGNTeamRemoteAdmin="true"
piUserPassword="tuapassword"  # Password utente pi
runAtBoot="/boot/setup_cron.sh"
GSMCenterFreq="950"
OGNCenterFreq="868.3"
GSMGain="40"
Altitude="1300"               # Altitudine in metri
wifiName="TuaRete"            # Solo per test in casa
wifiPassword="TuaPassword"
wifiCountry="IT"
```

### File /boot/config.txt

Aggiungi alla fine del file:

```
# I2C abilitato
dtparam=i2c_arm=on
# RTC DS3231 (commentato per evitare conflitti con ATtiny)
# dtoverlay=i2c-rtc,ds3231
# UART abilitato per SIM7080G
enable_uart=1
```

### File /boot/setup_cron.sh

Questo è il file più importante — viene eseguito ad ogni avvio e riconfigura tutto:

```bash
#!/bin/bash

# ============================================
# OGN Solar Receiver - Setup automatico
# Eseguito ad ogni avvio tramite OGN-receiver.conf
# ============================================

# 1. Forza timezone italiano
timedatectl set-timezone Europe/Rome

# 2. Attendi disponibilità rete per NTP
sleep 60
ntpdate -u pool.ntp.org

# 3. Carica modulo I2C per comunicazione DS3231
modprobe i2c-dev

# 4. Sincronizza DS3231 in UTC tramite i2cset
# Il DS3231 usa UTC, lo sketch ATtiny converte in CEST
H=$(date -u +%H)
M=$(date -u +%M)
HH=$(printf '%02x' $((10#${H}/10*16 + 10#${H}%10)))
MM=$(printf '%02x' $((10#${M}/10*16 + 10#${M}%10)))
i2cset -y 1 0x68 0x00 0x00
i2cset -y 1 0x68 0x01 0x$MM
i2cset -y 1 0x68 0x02 0x$HH

# 5. Installa pacchetti necessari (persi ad ogni reboot per overlay)
apt-get install -y screen minicom i2c-tools ppp > /dev/null 2>&1

# 6. Configura PPP per SIM7080G con Vodafone (opzionale)
# Decommenta se usi SIM7080G HAT
#
# cat > /etc/ppp/peers/vodafone << 'EOF'
# /dev/ttyAMA0 115200
# connect '/usr/sbin/chat -v -f /etc/ppp/chat-vodafone'
# noauth
# defaultroute
# usepeerdns
# persist
# holdoff 10
# maxfail 0
# EOF
#
# cat > /etc/ppp/chat-vodafone << 'EOF'
# TIMEOUT 30
# ABORT "ERROR"
# ABORT "NO CARRIER"
# "" AT
# OK AT+CFUN=1
# OK AT+CGDCONT=1,"IP","vo.vodafone.it"
# OK ATD*99#
# CONNECT ""
# EOF
#
# pppd call vodafone &

# 7. Crontab ROOT per shutdown automatico sicuro
# Lo shutdown avviene 5 minuti prima del taglio alimentazione ATtiny
crontab -u root -l 2>/dev/null | \
  grep -v shutdown | \
  grep -v reboot > /tmp/crontab_tmp
echo "55 18 * * * /sbin/shutdown -h now" >> /tmp/crontab_tmp
echo "0 19 * * * /sbin/shutdown -h now" >> /tmp/crontab_tmp
crontab -u root /tmp/crontab_tmp
rm /tmp/crontab_tmp
```

Rendi eseguibile lo script:
```bash
chmod +x /boot/setup_cron.sh
```

---

## Configurazione SIM7080G

### Prerequisiti

- SIM card compatibile NB-IoT/Cat-M (Vodafone IT consigliata)
- SIM card 1.8V o dual voltage (1.8V/3V)
- HAT montato sul Raspberry Pi 4

### Test connessione AT

```bash
sudo apt-get install -y screen
sudo screen /dev/ttyAMA0 115200
```

Comandi AT di verifica:
```
AT                    → OK (modulo risponde)
AT+CPIN?              → +CPIN: READY (SIM riconosciuta)
AT+CIMI               → numero IMSI (22210... = Vodafone)
AT+CSQ                → qualità segnale (99,99 = nessun segnale)
AT+CEREG?             → stato registrazione rete
AT+COPS?              → operatore connesso
```

### Configurazione Vodafone NB-IoT

```
AT+CGDCONT=1,"IP","vo.vodafone.it"
AT+CFUN=1,1
```

Attendi 60 secondi poi verifica:
```
AT+CEREG?
```

Risposta attesa: `+CEREG: 0,1` (registrato) o `+CEREG: 0,5` (roaming)

### Attivare PPP in setup_cron.sh

Decommentare la sezione PPP nel file `/boot/setup_cron.sh` (sezione punto 6).

---

## Installazione e test

### Procedura di prima accensione

1. Flasha SD card con immagine OGN
2. Configura `/boot/OGN-receiver.conf` con i tuoi dati
3. Configura `/boot/config.txt`
4. Crea e configura `/boot/setup_cron.sh`
5. Collega hardware ATtiny85 con DS3231
6. Prima accensione con WiFi di casa per verifica

### Verifica sincronizzazione DS3231

Dopo il primo avvio verifica che il DS3231 sia sincronizzato:

```bash
# Carica modulo I2C se necessario
sudo modprobe i2c-dev

# Leggi ora UTC dal DS3231
sudo i2cget -y 1 0x68 0x02  # ore (BCD)
sudo i2cget -y 1 0x68 0x01  # minuti (BCD)

# Confronta con ora sistema UTC
date -u
```

I valori devono coincidere (convertendo da BCD a decimale).

### Verifica crontab shutdown

```bash
sudo crontab -l
```

Deve mostrare:
```
55 18 * * * /sbin/shutdown -h now
0 19 * * * /sbin/shutdown -h now
```

### Test ciclo accensione/spegnimento

1. Alle 10:00 CEST il relè deve chiudersi e il RPi accendersi
2. Alle 18:55 CEST il cron deve eseguire shutdown pulito
3. Alle 19:00 CEST l'ATtiny deve aprire il relè e togliere alimentazione

### Verifica tensione batteria

Con multimetro:
```
Batteria piena:  6.6V - 6.7V
Batteria media:  6.2V - 6.5V
Batteria scarica: < 5.6V (ATtiny spegne il RPi)
Batteria critica: < 4.7V (protezione assoluta)
```

---

## Troubleshooting

### ATtiny non comunica con DS3231

**Sintomi:** 3 click lenti sul relè dopo avvio

**Soluzioni:**
1. Verifica collegamento SDA (P0) e SCL (P3)
2. Verifica pull-up su P3 (resistenza verso 5V)
3. Verifica alimentazione DS3231 (5V e GND)
4. Non usare P2 per SCL — problemi con bootloader Micronucleus v1.6

### Relè oscilla all'avvio

**Sintomi:** RPi si accende e spegne in continuazione

**Cause:**
- Modulo relè su LOW trigger invece di HIGH trigger
- Tensione alimentazione instabile

**Soluzioni:**
1. Verificare ponticello modulo relè su HIGH trigger
2. Aggiungere condensatore 100µF su VCC ATtiny

### DS3231 perde l'ora

**Sintomi:** ATtiny legge ore 0 o valori assurdi

**Soluzioni:**
1. Sostituire batteria CR2032 del DS3231
2. Verificare che lo script setup_cron.sh sincronizzi correttamente
3. Verificare che i2cset scriva correttamente (modulo i2c-dev caricato)

### RPi non si accende alle 10:00

**Verificare:**
```bash
# Ora DS3231
sudo modprobe i2c-dev
sudo i2cget -y 1 0x68 0x02  # deve essere 0x08 alle 10 CEST

# Tensione batteria su P4
# ADC deve essere >= 280
```

### RPi non si spegne alle 19:00

**Verificare:**
```bash
sudo crontab -l
timedatectl
```

Timezone deve essere Europe/Rome. Se il crontab non funziona, il taglio avviene comunque tramite ATtiny alle 19:00 — con overlay attivo non ci sono danni alla SD.

### SIM7080G non aggancia la rete

**Verificare:**
```bash
sudo screen /dev/ttyAMA0 115200
AT+CSQ    # deve essere diverso da 99,99
AT+CEREG? # deve essere 0,1 o 0,5
```

**Soluzioni:**
1. Verificare antenna collegata
2. Verificare APN operatore
3. Provare SIM Vodafone o TIM (migliore copertura NB-IoT)

---

## Bilancio energetico

### Consumi sistema

| Componente | Corrente | Note |
|------------|---------|------|
| Raspberry Pi 4 | 270-360 mA | Media con SDR |
| Modulo relè | 20 mA | Solo quando attivo |
| ATtiny85 + DS3231 | 15 mA | Sempre attivo |
| SIM7080G (idle) | 39 mA | Se installato |
| **Totale con RPi acceso** | **~360 mA** | |
| **Totale con RPi spento** | **~15 mA** | Solo ATtiny |

### Calcolo autonomia senza sole

```
Batteria: 6Ah (reale ~5.8Ah)
Range utile LiFePO4: 5.6V - 6.6V (≈75% capacità)
Capacità disponibile: 5.8 × 0.75 = 4.35 Ah

Consumo giornaliero:
  RPi acceso 9h:  360mA × 9h  = 3.24 Ah
  RPi spento 15h: 15mA × 15h  = 0.22 Ah
  Totale:                      = 3.46 Ah

Autonomia senza sole = 4.35 / 3.46 = ~1.3 giorni
```

### Produzione pannello solare 9W

```
Ore sole utile in montagna: 5h/giorno
Efficienza DC/DC: 85%
Produzione: 9W × 0.85 / 5.1V × 5h = 7.5 Ah/giorno

Surplus giornaliero: 7.5 - 3.46 = +4 Ah ✅
```

Il sistema è energeticamente positivo nelle giornate soleggiate.

---

## Note finali

### Fuso orario

Il DS3231 è configurato in UTC. Lo sketch ATtiny usa:
- `ORA_ACCENSIONE = 8` (8 UTC = 10:00 CEST, ora legale italiana)
- `ORA_SPEGNIMENTO = 17` (17 UTC = 19:00 CEST)

In inverno (CET = UTC+1) sarà necessario aggiornare questi valori:
- `ORA_ACCENSIONE = 9` (9 UTC = 10:00 CET)
- `ORA_SPEGNIMENTO = 18` (18 UTC = 19:00 CET)

### Protezione SD card

L'immagine OGN usa overlay filesystem — tutti i file di sistema sono in sola lettura. Solo `/boot` è scrivibile e persistente. Questo garantisce che spegnimenti bruschi non danneggino mai la SD card.

### Manutenzione

- Verificare tensione batteria periodicamente
- Sostituire batteria CR2032 DS3231 ogni 2-3 anni
- Aggiornare gli orari UTC quando cambia l'ora legale

### Risorse utili

- OGN Wiki: http://wiki.glidernet.org
- Immagine OGN: http://download.glidernet.org/seb-ogn-rpi-image
- Waveshare SIM7080G Wiki: https://www.waveshare.com/wiki/SIM7080G_Cat-M/NB-IoT_HAT
- SoftI2CMaster library: https://github.com/felias-fogg/SoftI2CMaster

---

*Documentazione basata su installazione reale in Umbria/Marche, 1300m s.l.m.*  
*Callsign operatore: IU6SVB*