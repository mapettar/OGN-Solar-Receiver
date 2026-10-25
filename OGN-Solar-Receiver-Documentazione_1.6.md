# Stazione OGN Solare Autonoma
## Guida completa alla costruzione, configurazione e ripristino

**Versione:** 1.7  
**Data:** Ottobre 2026  
**Basata su:** installazione reale in montagna (Umbria/Toscana, 1300 m s.l.m.)  
**Operatore:** IU6SVB

> **Novità v1.7**
> - Batteria **Li-ion 3S2P 18650** + caricatore MPPT **CN3791 3S** + **TPS54560** + pannello 20 W + interruttore generale
> - Partitore batteria P4 con **R1 = 56 kΩ / R2 = 10 kΩ** e nuove soglie ADC
> - **Tetto assoluto 19:00 CEST**: la stazione si spegne sempre entro quell'ora, anche se le effemeridi darebbero più tardi
> - **Orologio DS3231 perso** (alimentazione a zero): l'ATtiny riaccende comunque la RPi, che si risincronizza via NTP
> - **Shutdown indipendente dal fuso del cron** (misurato: il cron della RPi leggeva l'ora locale)
> - **Corretto errore nella formula del tramonto** di `calc_sunset.py` (v1.6 dava un tramonto quasi costante tutto l'anno)
> - Nuova sezione **Ripristino su nuova SD** con tutti i comandi SSH e da Mac
> - Monitoraggio INA219, accesso Tailscale, notizie su RPi Zero 2W

---

## Indice

1. [Introduzione](#introduzione)
2. [Hardware necessario](#hardware-necessario)
3. [Schema elettrico](#schema-elettrico)
4. [Montaggio hardware](#montaggio-hardware)
5. [Sketch ATtiny85 v1.7.2](#sketch-attiny85-v172)
6. [Configurazione Raspberry Pi](#configurazione-raspberry-pi)
7. [Spegnimento dinamico e tetto 19:00 CEST](#spegnimento-dinamico-e-tetto-1900-cest)
8. [Monitoraggio batteria INA219](#monitoraggio-batteria-ina219)
9. [Accesso remoto Tailscale](#accesso-remoto-tailscale)
10. [Configurazione SIM7080G](#configurazione-sim7080g)
11. [Installazione e test](#installazione-e-test)
12. [Ripristino su nuova SD / nuova RPi](#ripristino-su-nuova-sd--nuova-rpi)
13. [Backup](#backup)
14. [Troubleshooting](#troubleshooting)
15. [Bilancio energetico](#bilancio-energetico)
16. [Note finali](#note-finali)

---

## Introduzione

Stazione ricevitore OGN (Open Glider Network) autonoma, alimentata da pannello solare e batteria, per zone senza rete elettrica né WiFi.

Alle 10:00 CEST un ATtiny85 legge l'orario da un RTC DS3231 e chiude un relè che alimenta la Raspberry Pi. La RPi calcola il tramonto con le effemeridi e si spegne da sola; poco dopo l'ATtiny apre il relè. In ogni caso **l'alimentazione viene tolta entro le 19:00 CEST** e prima che la batteria scenda sotto la soglia di sicurezza.

### Caratteristiche principali

- Accensione automatica alle 10:00 CEST (08:00 UTC) tramite DS3231
- Spegnimento dinamico: tramonto − 90 minuti, **mai oltre 18:55 CEST (shutdown) e 19:00 CEST (taglio relè)**
- Se il DS3231 perde l'ora la RPi viene accesa comunque, riparte da 00:00 e si risincronizza via NTP
- Protezione batteria Li-ion 3S prima del BMS
- Filesystem in sola lettura (overlay) per proteggere la SD
- Sincronizzazione NTP → DS3231 ad ogni avvio, con retry
- Accesso SSH remoto con Tailscale (WiFi o SIM)
- Monitoraggio tensione/corrente con INA219
- SIM7080G opzionale per la connettività mobile

---

## Hardware necessario

| Componente | Specifiche | Note |
|------------|-----------|------|
| Raspberry Pi 4 (1 GB sufficiente) | Immagine OGN | Prova riuscita anche con **RPi Zero 2W** (CPU OGN ~85%, 55 °C) |
| ATtiny85 Digispark | Micronucleus v1.6 | Controller accensione |
| DS3231 | Modulo ZS-042 | Resistenza di carica (sigla 102) **rimossa** → con CR2032 non ricaricabile; meglio LIR2032 |
| Modulo relè | HIGH trigger, con MOSFET | Alimentazione RPi |
| BSS138 | Level shifter I2C | 3.3 V (RPi) ↔ 5 V (DS3231/ATtiny) |
| INA219 | Modulo, indirizzo 0x40 | Collegato **direttamente** a GPIO2/GPIO3 (3.3 V), non sul BSS138 |
| DC/DC buck | **TPS54560** (5 A) | Uscita regolata a 5.1 V. (prima: TPS63070 per il 2S) |
| Batteria | **Li-ion 3S2P 18650 3200 mAh** (6.4 Ah, 12.6 V max) con BMS 3S | Prima: LiFePO4 2S 6 Ah |
| Caricatore MPPT | **CN3791 3S** (modulo AliExpress, taglio 12.6 V) | Ingresso fino a 28 V |
| Pannello | **20 W 18 V** (VEVOR, controller integrato rimosso) | Voc a freddo ~25 V: sotto il limite 28 V del caricatore |
| Interruttore generale | Adatto a 12 V / 2 A | Tra uscita BMS e IN+ del TPS54560 |
| SIM7080G HAT | Waveshare, SIM 1.8 V | UART `/dev/ttyAMA0` 115200, APN `vo.vodafone.it` |

### Componenti elettronici

| Componente | Valore | Utilizzo |
|------------|--------|----------|
| R1 | **56 kΩ** | Partitore batteria 3S (lato alto) |
| R2 | 10 kΩ | Partitore batteria (lato basso) |
| C2 | 100 nF ceramico | Tra P4 e GND, stabilizza la lettura ADC |
| D1 | 1N5817 Schottky | In serie su VCC ATtiny |
| C1 | 100 µF elettrolitico (+ sul nodo VCC) | Su VCC ATtiny, dopo D1 |
| C1b | 100 nF ceramico (104) | In parallelo a C1, vicino al Digispark |

---

## Schema elettrico

### Schema generale

![Schema dei collegamenti tra i moduli (pacco 3S)](images/schema-collegamenti-3s.png)

*Schema dei collegamenti per il pacco 3S (file modificabile: `images/schema-collegamenti-3s.svg`). Sotto trovi lo stesso schema in forma testuale.*

```
Pannello 20W 18V
      |
  CN3791 3S MPPT (taglio 12.6V)
      |
      +------------------------+
      |                        |
  Batteria 3S2P Li-ion --- BMS 3S ---- P+ -----+---- INA219 (VIN+) -> VIN- --+
                                               |                             |
                                               +--- partitore P4 (R1/R2)     |
                                               |                             |
                                          [INTERRUTTORE]                     |
                                               |                             |
                                       TPS54560 IN+  <-----------------------+
                                               |
                                            5.1 V
                     +-------------------------+----------------------+
                     |                         |                      |
              ATtiny85 + DS3231           Modulo relè            SIM7080G HAT
              (via D1 1N5817)                  |                 (opzionale)
                                          Raspberry Pi
```

Note:
- Il **caricatore resta collegato anche con l'interruttore aperto**: il pannello continua a ricaricare quando la stazione è ferma.
- Il partitore P4 e l'INA219 stanno **lato batteria**, prima dell'interruttore.
- Il caricatore va sul BMS (P+ / P−), non direttamente sulle celle.
- Prima di collegare il pannello: misura la tensione a vuoto (Voc) e controlla che resti sotto 28 V.

### Collegamenti ATtiny85

![Pinout Digispark ATtiny85](images/digispark-pinout.png)

*Pinout della Digispark (immagine di terzi). Attenzione: P3 e P4 sono usati anche dal collegamento USB; P3 ha il pull-up da 1,5 kΩ. Su alcune cloni P5 è configurato come reset.*

```
ATtiny85 Digispark      Collegamento
------------------      ------------
P0 (SDA)         ------ SDA DS3231 (lato HV del BSS138)
P1 (Relè)        ------ IN modulo relè (HIGH trigger)
P2                      NON USARE (problemi bootloader v1.6)
P3 (SCL)         ------ SCL DS3231 (lato HV del BSS138)  [pull-up già sul Digispark (1,5 kΩ) e sul modulo DS3231]
P4 (A2, ADC)     ------ nodo partitore batteria (+ 100 nF verso GND)
5V               ------ catodo 1N5817 (anodo sul 5.1 V) + 100 µF verso GND
GND              ------ GND
```

### Level shifter BSS138

![Pinout GPIO Raspberry Pi](images/rpi-gpio-pinout.png)

*Connettore GPIO a 40 pin (immagine di terzi, foto di una Pi 2 Model B: il connettore è identico a quello della Pi 3A+). I2C della stazione: pin 3 = GPIO2 (SDA), pin 5 = GPIO3 (SCL), 3,3 V sul pin 1, GND sul pin 6 o 9.*

```
LV  (3.3V) -------- RPi 3.3 V
HV  (5.0V) -------- 5.1 V alimentazione
LV1        -------- RPi GPIO2 (SDA, pin 3)
LV2        -------- RPi GPIO3 (SCL, pin 5)
HV1        -------- SDA DS3231 + ATtiny P0
HV2        -------- SCL DS3231 + ATtiny P3
GND        -------- GND comune
```

L'INA219 (alimentato a 3.3 V) va invece su pin 3 e 5 della RPi, **senza** passare dal BSS138. VIN+ sul + batteria (uscita BMS), VIN− sul + che va verso il TPS54560.

### Partitore batteria su P4 (Li-ion 3S)

```
+ batteria (P+, prima dell'interruttore)
      |
    R1 56 kΩ
      |
      +-------- P4 (A2) ATtiny85 ----- C2 100 nF -- GND
      |
    R2 10 kΩ
      |
     GND
```

Rapporto 10/66 = 0.1515: a 12.6 V sul pin ci sono 1.91 V (ben sotto la VCC dell'ATtiny). Impedenza vista dall'ADC ≈ 8.5 kΩ, quindi ok con i 100 nF. Assorbimento permanente del partitore: 0.19 mA.

> **R1: 56 kΩ o 62 kΩ?** Vanno bene entrambe (con 62 kΩ: 12.6 V → 1.75 V). Il valore di riferimento è **56 kΩ**: dà più risoluzione nella zona critica 9–10 V ed è quello per cui sono calcolate le soglie dello sketch. Se usi 62 kΩ riscala le soglie (×0.92) o ricalibra misurando.

### Soglie ADC (R1 = 56 kΩ, R2 = 10 kΩ)

L'ADC dell'ATtiny usa VCC come riferimento. VCC = 5.1 V − caduta del 1N5817 ≈ **4.8 V** (misura il tuo valore!).

| Batteria | Pin P4 | ADC (VCC 4.8 V) | Intervallo (VCC 4.6–5.0 V) | Stato |
|----------|--------|-----------------|----------------------------|-------|
| 12.6 V | 1.91 V | 407 | 391–425 | Piena |
| 12.0 V | 1.82 V | 388 | 372–404 | Buona |
| 11.1 V | 1.68 V | 358 | 344–374 | Nominale |
| **10.5 V** | 1.59 V | **339** | 326–354 | **Riaccensione** (`SOGLIA_BATT_ON` = 340) |
| 10.2 V | 1.55 V | 329 | 316–344 | Bassa |
| **9.6 V** | 1.46 V | **310** | 298–323 | **Spegnimento** (`SOGLIA_BATT_MIN` = 310) |
| 9.0 V | 1.36 V | 291 | 279–303 | Zona pericolosa |

Il BMS 3S interviene più in basso (tipicamente 7.5–9 V secondo il modello): l'ATtiny deve spegnere **prima**.

**Calibrazione:** con un alimentatore da banco o con la batteria, misura la tensione reale e sposta le due soglie di conseguenza: `ADC = Vbatt × 0.1515 / VCC × 1023`.

### Modulo relè HIGH trigger

```
ATtiny P1 ---- IN
5.1 V     ---- VCC
GND       ---- GND
Ponticello: HIGH trigger

P1 LOW  = relè aperto  = RPi SPENTA (stato sicuro all'avvio dell'ATtiny)
P1 HIGH = relè chiuso  = RPi ACCESA
```

---

## Montaggio hardware

1. **Partitore:** + batteria → R1 (56 kΩ) → nodo P4 → R2 (10 kΩ) → GND, con 100 nF tra P4 e GND.
2. **Diodo:** 5.1 V → anodo 1N5817 → catodo → VCC Digispark. Evita i reset quando la RPi assorbe corrente all'avvio.
3. **Condensatori:** VCC Digispark → 100 µF (+ sul nodo) → GND, e 100 nF (104) in parallelo. Nessuna resistenza di pull-up aggiuntiva su SCL.
5. **BSS138:** lato LV su RPi GPIO2/GPIO3 + 3.3 V, lato HV su DS3231 e ATtiny P0/P3 + 5 V, GND comune.
6. **INA219:** pin 3 e 5 della RPi, 3.3 V, GND; VIN+/VIN− come da schema.
7. **Interruttore:** tra uscita BMS (P+) e IN+ del TPS54560. Caricatore, partitore e INA219 prima dell'interruttore.
8. **Regola il TPS54560 a 5.1 V a vuoto**, prima di collegare la RPi.

---

## Sketch ATtiny85 v1.7.2

### Libreria e IDE

- Libreria **SoftI2CMaster** (Bernhard Nebel / Felias Fogg), dal Library Manager
- Board: Digispark (Default - 16.5 MHz), Programmer: Micronucleus
- Memoria: ben sotto il limite di ~6012 byte del bootloader v1.6

### Sketch

```cpp
// OGN Solar Receiver - ATtiny85 Digispark - v1.7.2 (anti-glitch I2C)
// - Tutti gli orari sono UTC (CEST = UTC+2)
// - Tetto assoluto: la stazione si spegne SEMPRE entro 17:00 UTC (= 19:00 CEST)
// - Taglio dinamico: registro allarme DS3231 (scritto dalla RPi = tramonto - 88 min)
// - Orologio perso (DS3231 senza alimentazione): accende comunque la RPi,
//   che si risincronizza via NTP e riscrive l'ora
// - Batteria Li-ion 3S2P: partitore R1=56k / R2=10k su P4

#define SDA_PORT PORTB
#define SDA_PIN 0      // P0 = SDA
#define SCL_PORT PORTB
#define SCL_PIN 3      // P3 = SCL (NON usare P2)

#include <SoftI2CMaster.h>

#define DS3231_ADDR          0x68
#define RELAY_PIN            1      // P1 = rele HIGH trigger
#define BATT_PIN             A2     // P4 = partitore batteria

// ---- Orari (UTC) ----
#define ORA_ACCENSIONE       8      // 08:00 UTC = 10:00 CEST (inverno CET: 9)
#define ORA_SPEGNIMENTO_MAX  17     // 17:00 UTC = 19:00 CEST (inverno CET: 18)

// ---- Soglie ADC batteria 3S Li-ion (R1=56k, R2=10k, VCC ATtiny ~4.8V) ----
// ADC = Vbatt * 0.1515 / VCC * 1023  ->  ~32.3 conteggi per volt
#define SOGLIA_BATT_MIN      310    // ~9.6V  spegne (BMS interviene piu in basso)
#define SOGLIA_BATT_ON       340    // ~10.5V riaccende

// ---- Orologio non valido: cicli ON/OFF finche la RPi non riscrive l'ora ----
#define INVALIDO_ON_MS       7200000UL   // 2 h acceso
#define INVALIDO_OFF_MS      1800000UL   // 30 min spento
#define FINESTRA_BOOT_MS     300000UL    // 00:00-00:04 dopo il boot ATtiny = ora persa

// ==== INIZIO LOGICA PURA (testata su PC, nessun accesso hardware) ====
uint8_t bcd2dec(uint8_t bcd) {
  return ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F);
}

bool bcdValido(uint8_t bcd) {
  return (bcd & 0x0F) <= 9 && ((bcd >> 4) & 0x0F) <= 9;
}

// Minuti (UTC) del taglio rele: allarme DS3231, mai oltre il tetto 17:00 UTC
uint16_t calcolaTaglio(uint8_t oreAl, uint8_t minAl) {
  uint16_t tetto = (uint16_t)ORA_SPEGNIMENTO_MAX * 60;
  if (oreAl <= ORA_ACCENSIONE || oreAl >= 24 || minAl >= 60) return tetto;
  uint16_t t = (uint16_t)oreAl * 60 + minAl;
  return (t < tetto) ? t : tetto;
}

bool inFinestra(uint16_t adessoMin, uint16_t taglioMin) {
  return adessoMin >= (uint16_t)ORA_ACCENSIONE * 60 && adessoMin < taglioMin;
}

// Orologio da considerare perso?
bool orologioPerso(bool lettureOk, uint8_t status, uint8_t ore, uint8_t minuti,
                   unsigned long uptimeMs) {
  if (!lettureOk) return true;                    // DS3231 non risponde
  if (status & 0x80) return true;                 // OSF: oscillatore fermo
  if (ore > 23 || minuti > 59) return true;       // valori assurdi
  if (ore == 0 && minuti < 5 && uptimeMs < FINESTRA_BOOT_MS) return true;
  return false;
}

// Stato desiderato del rele. dtMs = ms dall'ultimo cambio di stato.
bool vuoleRele(bool releAcceso, bool perso, uint16_t adessoMin,
               uint16_t taglioMin, int adc, unsigned long dtMs) {
  int soglia = releAcceso ? SOGLIA_BATT_MIN : SOGLIA_BATT_ON;
  if (adc < soglia) return false;                 // protezione batteria sempre prima
  if (perso) {
    // Orologio perso: parte comunque, a cicli, fino a risincronizzazione
    return releAcceso ? (dtMs < INVALIDO_ON_MS) : (dtMs >= INVALIDO_OFF_MS);
  }
  return inFinestra(adessoMin, taglioMin);
}
// ==== FINE LOGICA PURA ====

bool leggiRegistri(uint8_t reg, uint8_t *buf, uint8_t n) {
  if (!i2c_start((DS3231_ADDR << 1) | I2C_WRITE)) { i2c_stop(); return false; }
  i2c_write(reg);
  i2c_stop();
  if (!i2c_start((DS3231_ADDR << 1) | I2C_READ)) { i2c_stop(); return false; }
  for (uint8_t i = 0; i < n; i++) buf[i] = i2c_read(i == n - 1);
  i2c_stop();
  return true;
}

int leggiADC() {
  long somma = 0;
  for (int i = 0; i < 5; i++) {
    somma += analogRead(BATT_PIN);
    delay(10);
  }
  return somma / 5;
}

bool statoRele = false;
unsigned long tCambio;
uint8_t erroriI2C = 0;       // letture I2C consecutive fallite

void impostaRele(bool acceso) {
  digitalWrite(RELAY_PIN, acceso ? HIGH : LOW);
  if (acceso != statoRele) tCambio = millis();
  statoRele = acceso;
}

void setup() {
  pinMode(RELAY_PIN, OUTPUT);
  pinMode(BATT_PIN, INPUT);
  digitalWrite(RELAY_PIN, LOW);               // HIGH trigger: LOW = RPi spenta
  tCambio = 0UL - INVALIDO_OFF_MS;            // il primo ciclo "spento" risulta gia scaduto
  i2c_init();
  delay(500);
}

void loop() {
  uint8_t ora[3] = {0, 0, 0}, al[3] = {0, 0, 0}, st = 0;
  bool ok = leggiRegistri(0x00, ora, 3);
  ok = ok && leggiRegistri(0x07, al, 3);
  ok = ok && leggiRegistri(0x0F, &st, 1);

  bool bcdOk = bcdValido(ora[1]) && bcdValido(ora[2]);   // solo l'ora: un allarme sporco non rende perso l'orologio

  // Un singolo errore di lettura (disturbo, RPi che usa il bus) NON cambia nulla:
  // si salta il ciclo. Solo 3 errori consecutivi = DS3231 non raggiungibile.
  if (ok && bcdOk) {
    erroriI2C = 0;
  } else {
    if (erroriI2C < 3) erroriI2C++;
    if (erroriI2C < 3) { delay(5000); return; }
  }
  uint8_t ore = bcd2dec(ora[2] & 0x3F);
  uint8_t minuti = bcd2dec(ora[1] & 0x7F);
  bool perso = orologioPerso(erroriI2C < 3, st, ore, minuti, millis());

  uint8_t oreAl = bcd2dec(al[2] & 0x3F);
  uint8_t minAl = bcd2dec(al[1] & 0x7F);
  uint16_t taglio = calcolaTaglio(oreAl, minAl);
  uint16_t adesso = (uint16_t)ore * 60 + minuti;

  int adc = leggiADC();
  impostaRele(vuoleRele(statoRele, perso, adesso, taglio, adc, millis() - tCambio));

  delay(30000);   // controlla ogni 30 secondi
}
```

La logica di decisione (blocco "LOGICA PURA") è stata provata su PC con 39 scenari: giorno normale, taglio dinamico, tetto 17:00 UTC, batteria con isteresi, orologio perso, resincronizzazione e una scansione esaustiva di tutte le combinazioni ora/allarme.

Dalla v1.7.2 un singolo errore di lettura I2C (disturbo, RPi che accede al bus nello stesso istante) viene ignorato: servono 3 letture consecutive fallite perché il DS3231 sia considerato non raggiungibile. Il flag OSF e l'ora 00:00 appena dopo l'avvio restano invece riconosciuti subito.

### Come decide l'ATtiny (ogni 30 secondi)

| Situazione | Comportamento |
|------------|---------------|
| Batteria < `SOGLIA_BATT_MIN` (9.6 V) | Relè **aperto**, sempre, prima di ogni altra regola |
| Orologio valido, 08:00 ≤ ora < taglio | Relè chiuso (se batteria ≥ `SOGLIA_BATT_ON` quando è spento) |
| Orologio valido, fuori finestra | Relè aperto |
| **Taglio** | `min(allarme DS3231, 17:00 UTC)`: l'orario scritto dalla RPi (tramonto − 88 min) non supera mai le 19:00 CEST |
| Allarme DS3231 non valido (0, ≤ 8, > 23, BCD errato) | Usa il tetto 17:00 UTC |
| **Orologio perso** | Relè chiuso comunque (batteria permettendo), vedi sotto |

### Orologio perso (DS3231 senza alimentazione)

Quando la tensione scende a zero il DS3231 (senza batteria tampone) perde ora e allarme e riparte da 00:00. L'ATtiny lo riconosce se **una** di queste condizioni è vera:

1. flag **OSF** (registro 0x0F, bit 7) = 1: oscillatore fermato
2. il DS3231 non risponde sull'I2C
3. valori assurdi (ore > 23, minuti > 59, BCD non valido)
4. ora 00:00–00:04 nei primi 5 minuti dall'avvio dell'ATtiny

In questo caso l'ATtiny **accende la RPi comunque**. La RPi al boot esegue NTP, scrive l'ora UTC sul DS3231 e **azzera OSF** (`setup_cron.sh`), poi ricalcola l'allarme: dal ciclo successivo (30 s) l'ATtiny torna alla logica normale. Se la RPi riscrive l'ora fuori dalla finestra (es. dopo le 19:00 CEST) il relè si apre.

Se l'ora **non** viene risincronizzata (nessuna rete) l'ATtiny funziona a cicli **2 ore acceso / 30 minuti spento** finché il DS3231 non è valido, con la protezione batteria sempre attiva. In questa condizione il tetto delle 19:00 non può essere garantito, perché manca un orologio affidabile: è l'unico caso.

> Se l'orologio è perso e il relè è già chiuso quando la RPi riscrive l'ora, nulla si spegne: il relè resta chiuso e la RPi continua a girare.

---

## Configurazione Raspberry Pi

### Immagine OGN base

```
http://download.glidernet.org/seb-ogn-rpi-image
```

### File /boot/OGN-receiver.conf

```
### Mandatory ###
ReceiverName="TUONOME"
Latitude="43.349721"
Longitude="12.773177"

### Optional ###
EnableCoreOGNTeamRemoteAdmin="true"
piUserPassword="CAMBIA_QUESTA_PASSWORD"
runAtBoot="/boot/setup_cron.sh"
GSMCenterFreq="950"
OGNCenterFreq="868.3"
GSMGain="40"
Altitude="1300"
wifiName="TuaRete"
wifiPassword="TuaPassword"
wifiCountry="IT"
```

### File /boot/config.txt (righe da avere)

```
dtparam=i2c_arm=on
# dtoverlay=i2c-rtc,ds3231   (lasciare commentato: conflitto con l'ATtiny)
enable_uart=1
```

Con la SIM7080G sulla UART principale serve anche liberare la seriale dalla console (`raspi-config` → Interface Options → Serial: console **no**, hardware serial **sì**).

### File /boot/calc_sunset.py (v1.7)

Calcola il tramonto, riscrive il crontab e scrive il taglio relè nel DS3231. Applica i tetti: shutdown ≤ 16:55 UTC, taglio relè ≤ 17:00 UTC.

```python
#!/usr/bin/env python3
# calc_sunset.py v1.7 - calcolo tramonto senza librerie esterne
# - imposta lo shutdown nel crontab (tramonto - 90 min)
# - scrive nel registro allarme DS3231 l'ora di taglio del rele (tramonto - 88 min)
# - TETTO ASSOLUTO: shutdown max 16:55 UTC, taglio rele max 17:00 UTC (= 19:00 CEST)
# Uso:  python3 /boot/calc_sunset.py            (calcolo normale)
#       python3 /boot/calc_sunset.py --fallback (solo orari fissi, es. NTP assente)

import math
import datetime
import subprocess
import sys

# === CONFIGURAZIONE ===
LAT = 43.349721
LON = 12.773177
MARGINE_SHUTDOWN = 90          # minuti prima del tramonto: shutdown cron
MARGINE_RELE     = 88          # minuti prima del tramonto: taglio rele ATtiny
TETTO_SHUTDOWN   = (16, 55)    # UTC = 18:55 CEST
TETTO_RELE       = (17, 0)     # UTC = 19:00 CEST (deve coincidere con lo sketch ATtiny)
INIZIO_GIORNO    = 8           # UTC: l'ATtiny accende alle 08:00 UTC
# Il DS3231 lavora in UTC. Le righe di cron controllano ogni minuto 'date -u':
# lo shutdown non dipende dal fuso con cui il demone cron legge il crontab.


def calcola_tramonto(lat, lon, data=None):
    """Ora del tramonto in UTC (ore decimali) oppure None."""
    if data is None:
        data = datetime.date.today()
    N = data.timetuple().tm_yday
    lng_ora = lon / 15.0
    t = N + (18 - lng_ora) / 24
    M = (0.9856 * t) - 3.289
    L = M + (1.916 * math.sin(math.radians(M))) + \
        (0.020 * math.sin(math.radians(2 * M))) + 282.634
    L = L % 360
    RA = math.degrees(math.atan(0.91764 * math.tan(math.radians(L)))) % 360
    Lquadrant = (math.floor(L / 90)) * 90
    RAquadrant = (math.floor(RA / 90)) * 90
    RA = (RA + (Lquadrant - RAquadrant)) / 15
    sinDec = 0.39782 * math.sin(math.radians(L))
    cosDec = math.cos(math.asin(sinDec))
    # zenith 90.833 gradi: cos = -0.01454 (manca nella v1.6: errore corretto)
    cosH = (-0.01454 - sinDec * math.sin(math.radians(lat))) / \
           (cosDec * math.cos(math.radians(lat)))
    if cosH > 1 or cosH < -1:
        return None
    H = math.degrees(math.acos(cosH)) / 15
    T = H + RA - (0.06571 * t) - 6.622
    return (T - lng_ora) % 24


def calcola_orari(data=None):
    """Restituisce dict con minuti-UTC-del-giorno (shutdown, failsafe, rele)."""
    tetto_sh = TETTO_SHUTDOWN[0] * 60 + TETTO_SHUTDOWN[1]
    tetto_re = TETTO_RELE[0] * 60 + TETTO_RELE[1]
    tr = calcola_tramonto(LAT, LON, data)
    if tr is None:
        sh, re, tramonto = tetto_sh, tetto_re, None
    else:
        tramonto = int(round(tr * 60))
        sh = min(tramonto - MARGINE_SHUTDOWN, tetto_sh)
        re = min(tramonto - MARGINE_RELE, tetto_re)
    # sanity: l'orario deve restare dopo l'accensione, altrimenti usa il tetto
    if sh <= INIZIO_GIORNO * 60 or re <= INIZIO_GIORNO * 60:
        sh, re = tetto_sh, tetto_re
    failsafe = min(sh + 60, tetto_re)       # secondo shutdown di sicurezza
    return {"tramonto": tramonto, "shutdown": sh, "failsafe": failsafe, "rele": re}


def dec2bcd(val):
    return ((val // 10) << 4) | (val % 10)


def hhmm(minuti):
    return "%02d:%02d" % (minuti // 60, minuti % 60)


def scrivi_allarme_ds3231(minuti_giorno):
    ore, minuti = divmod(minuti_giorno, 60)
    for reg, val in ((0x07, 0x00), (0x08, dec2bcd(minuti)), (0x09, dec2bcd(ore))):
        subprocess.run(["i2cset", "-y", "1", "0x68", "0x%02x" % reg, "0x%02x" % val])


def riga_shutdown(minuti_giorno):
    """Riga di cron che scatta ogni minuto e spegne SOLO se l'ora UTC coincide.
    Il confronto usa 'date -u', quindi non dipende dal fuso orario del demone cron.
    Prima di spegnere scrive una riga in /boot/ogn-eventi.log (l'unico posto che
    sopravvive allo spegnimento: /tmp e /var/log sono in RAM)."""
    hhmm_utc = "%02d%02d" % (minuti_giorno // 60, minuti_giorno % 60)
    return ('* * * * * [ "$(date -u +\\%H\\%M)" = "' + hhmm_utc + '" ] && { echo "$(date -u \'+\\%F \\%T\') UTC shutdown '
            + hhmm_utc + '" >> /boot/ogn-eventi.log; sync; /sbin/shutdown -h now; }')


def aggiorna_crontab(o):
    r = subprocess.run(["crontab", "-u", "root", "-l"], capture_output=True, text=True)
    linee = [l for l in r.stdout.split("\n") if l.strip() and "shutdown" not in l]
    linee.append(riga_shutdown(o["shutdown"]))
    linee.append(riga_shutdown(o["failsafe"]))
    # cintura di sicurezza: tetto fisso 17:00 UTC (19:00 CEST) sempre presente
    linee.append(riga_shutdown(TETTO_RELE[0] * 60 + TETTO_RELE[1]))
    uniche = []
    for l in linee:               # niente righe duplicate
        if l not in uniche:
            uniche.append(l)
    subprocess.run(["crontab", "-u", "root", "-"], input="\n".join(uniche) + "\n", text=True)


if __name__ == "__main__":
    if "--fallback" in sys.argv:
        o = {"tramonto": None,
             "shutdown": TETTO_SHUTDOWN[0] * 60 + TETTO_SHUTDOWN[1],
             "failsafe": TETTO_RELE[0] * 60 + TETTO_RELE[1],
             "rele": TETTO_RELE[0] * 60 + TETTO_RELE[1]}
        print("Modalita fallback: orari fissi")
    else:
        o = calcola_orari()
    aggiorna_crontab(o)
    scrivi_allarme_ds3231(o["rele"])
    print("Tramonto UTC:      %s" % (hhmm(o["tramonto"]) if o["tramonto"] else "n/d"))
    print("Shutdown cron UTC: %s" % hhmm(o["shutdown"]))
    print("Failsafe UTC:      %s" % hhmm(o["failsafe"]))
    print("Taglio rele UTC:   %s" % hhmm(o["rele"]))
```

### File /boot/setup_cron.sh (v1.7)

```bash
#!/bin/bash
# /boot/setup_cron.sh v1.7 - eseguito ad ogni avvio (runAtBoot in OGN-receiver.conf)
# Log di questa esecuzione: cat /tmp/setup_cron.log
exec >> /tmp/setup_cron.log 2>&1
echo "=== setup_cron.sh $(date -u '+%F %T') UTC ==="

export PYTHONPATH="/boot/python-libs:$PYTHONPATH"

# Chiave Tailscale: metti qui la TUA chiave (Reusable, No expiry).
# Non pubblicarla mai su GitHub / in chat. Lascia il segnaposto per disattivare.
TS_AUTHKEY="tskey-auth-XXXXXXXXXXXX"

# 1. Timezone italiana e attesa rete
timedatectl set-timezone Europe/Rome
sleep 60

# 2. NTP con 6 tentativi (ntpdate ritorna 0 solo se sincronizza)
NTP_OK=0
for i in 1 2 3 4 5 6; do
  if ntpdate -u pool.ntp.org; then NTP_OK=1; break; fi
  sleep 20
done
echo "NTP_OK=$NTP_OK"

# 3. I2C e strumenti (l'overlay perde i pacchetti ad ogni reboot)
modprobe i2c-dev
modprobe i2c-bcm2835
which i2cset > /dev/null 2>&1 || apt-get install -y i2c-tools > /dev/null 2>&1

to_bcd() { printf '%02x' $(( $1 / 10 * 16 + $1 % 10 )); }

if [ "$NTP_OK" -eq 1 ]; then
  # 4. Scrive l'ora UTC sul DS3231 e azzera il flag "oscillatore fermato" (OSF).
  #    Finche OSF=1 l'ATtiny considera l'orologio perso (vedi sketch v1.7).
  T=$(date -u +%H:%M:%S)
  H=$((10#${T:0:2})); M=$((10#${T:3:2})); S=$((10#${T:6:2}))
  i2cset -y 1 0x68 0x02 0x$(to_bcd $H)
  i2cset -y 1 0x68 0x01 0x$(to_bcd $M)
  i2cset -y 1 0x68 0x00 0x$(to_bcd $S)
  i2cset -y 1 0x68 0x0f 0x00
  echo "DS3231 scritto: $T UTC"
  # 5. Tramonto da effemeridi: crontab shutdown + taglio rele (max 17:00 UTC)
  python3 /boot/calc_sunset.py
else
  # Senza NTP l'ora di sistema non e affidabile: non toccare il DS3231,
  # usa solo gli orari fissi di sicurezza (shutdown 16:55 UTC, taglio 17:00 UTC)
  echo "NTP non disponibile: modalita fallback"
  python3 /boot/calc_sunset.py --fallback
fi

# 6. Altri pacchetti (non critici)
which screen  > /dev/null 2>&1 || apt-get install -y screen  > /dev/null 2>&1
which minicom > /dev/null 2>&1 || apt-get install -y minicom > /dev/null 2>&1
which pppd    > /dev/null 2>&1 || apt-get install -y ppp     > /dev/null 2>&1

# 7. Tailscale (accesso SSH remoto)
if [ "$TS_AUTHKEY" != "tskey-auth-XXXXXXXXXXXX" ]; then
  which tailscale > /dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
  tailscale up --authkey="$TS_AUTHKEY" --accept-routes
fi

# 8. (opzionale) log batteria INA219 ogni 10 minuti
# (crontab -u root -l; echo "*/10 * * * * python3 /boot/monitor_batteria.py >> /tmp/batteria.log 2>&1") | crontab -u root -

echo "=== fine setup_cron.sh ==="

# 9. Registro che sopravvive allo spegnimento (in /boot): ultimo log + riga per ogni avvio
cp /tmp/setup_cron.log /boot/setup_cron.last.log
echo "$(date -u '+%F %T') UTC avvio NTP_OK=$NTP_OK" >> /boot/ogn-eventi.log
tail -n 200 /boot/ogn-eventi.log > /tmp/ogn-eventi.tmp && cat /tmp/ogn-eventi.tmp > /boot/ogn-eventi.log
sync
```

```bash
chmod +x /boot/setup_cron.sh /boot/calc_sunset.py /boot/monitor_batteria.py
```

> **Sicurezza:** la chiave Tailscale e la password della RPi **non** vanno mai incollate in chat, in issue o su GitHub. Nel repository pubblico lascia i segnaposto. Se una chiave è stata esposta, revocala subito (tailscale.com → Settings → Keys) e generane una nuova.

---

## Spegnimento dinamico e tetto 19:00 CEST

```
Ogni avvio RPi (setup_cron.sh):
  1. NTP ok  → scrive ora UTC sul DS3231 e azzera OSF
  2. calc_sunset.py:
       shutdown cron = min(tramonto - 90 min, 16:55 UTC)
       failsafe cron = shutdown + 60 min (max 17:00 UTC)
       cintura cron  = 17:00 UTC fisso
       (righe ogni minuto che confrontano date -u: indipendenti dal fuso del cron)
       taglio relè   = min(tramonto - 88 min, 17:00 UTC) → registri 0x07-0x09 DS3231
  3. NTP assente → solo orari fissi (shutdown 16:55 UTC, taglio 17:00 UTC)

ATtiny (ogni 30 s):
  taglio = min(allarme DS3231, 17:00 UTC); se ora >= taglio → relè aperto
```

Tre barriere indipendenti: cron della RPi (18:55 CEST), taglio relè dell'ATtiny dall'allarme (≤ 19:00 CEST) e tetto fisso nello sketch (19:00 CEST).

### Orari calcolati (2026, Umbria/Toscana lat 43.35 lon 12.77, orari locali)

| Data | Tramonto | Shutdown RPi | Taglio relè |
|------|---------|--------------|-------------|
| 1 aprile | 19:35 | 18:05 | 18:07 |
| 15 aprile | 19:51 | 18:21 | 18:23 |
| 15 maggio | 20:26 | 18:55 (tetto) | 18:58 |
| 21 giugno | 20:53 | 18:55 (tetto) | 19:00 (tetto) |
| 15 luglio | 20:47 | 18:55 (tetto) | 19:00 (tetto) |
| 15 agosto | 20:13 | 18:43 | 18:45 |
| 15 settembre | 19:20 | 17:50 | 17:52 |
| 12 ottobre | 18:32 | 17:02 | 17:04 |
| 24 ottobre | 18:12 | 16:42 | 16:44 |

L'algoritmo è stato confrontato con il calcolo NOAA su tutto l'anno: scarto massimo 1.8 minuti.

> **Errore corretto nella v1.7:** la v1.6 calcolava `cosH` senza il termine `sinDec × sin(lat)`. Il tramonto risultava quasi uguale tutto l'anno (circa 19:00 CEST). Se hai ancora la v1.6 sulla RPi, sostituisci `/boot/calc_sunset.py`.

### Registri DS3231 usati

```
0x00 secondi      0x01 minuti      0x02 ore (UTC)
0x07 = 0x00       0x08 minuti taglio relè      0x09 ore taglio relè (UTC)
0x0F bit 7 (OSF)  1 = orologio perso, azzerato dalla RPi dopo la scrittura dell'ora
```

I registri dell'allarme 1 sono usati solo come memoria (l'allarme non è abilitato). Il DS3231 contiene **UTC**, la `hwclock` della RPi non si usa.

### Ora legale / solare

| Periodo | ORA_ACCENSIONE | ORA_SPEGNIMENTO_MAX | TETTO_SHUTDOWN / TETTO_RELE |
|---------|----------------|---------------------|-----------------------------|
| CEST (fine marzo – fine ottobre) | 8 | 17 | (16,55) / (17,0) |
| CET (inverno) | 9 | 18 | (17,55) / (18,0) |

Gli orari dello sketch e di `calc_sunset.py` vanno cambiati insieme. Il DS3231 non conosce l'ora legale: i tetti sono in UTC.

---

## Monitoraggio batteria INA219

Librerie Python **persistenti** in `/boot/python-libs` (con l'overlay attivo tutto il resto va perso al riavvio).

```bash
# Installazione (una volta sola, a overlay attivo va bene)
pip3 install --target=/home/pi/python-libs adafruit-circuitpython-ina219
# se pip rifiuta: aggiungere --break-system-packages
sudo cp -r /home/pi/python-libs /boot/python-libs
```

`/boot` non accetta scritture dirette di pip: da qui la copia con `sudo cp`.

### File /boot/monitor_batteria.py

```python
#!/usr/bin/env python3
# monitor_batteria.py v1.7 - INA219 (0x40) su GPIO2/GPIO3 della RPi, alimentato a 3.3V
# Pacco Li-ion 3S2P (12.6V pieno). Librerie in /boot/python-libs.
import sys
sys.path.insert(0, '/boot/python-libs')

import board
import busio
from adafruit_ina219 import INA219
import datetime

i2c = busio.I2C(board.SCL, board.SDA)
ina = INA219(i2c)
ina.set_calibration_32V_2A()

tensione = ina.bus_voltage            # V (lato batteria, VIN+)
corrente = ina.current                # mA
potenza = tensione * (corrente / 1000.0)   # W calcolati a mano
timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

print(f"[{timestamp}]")
print(f"Tensione:  {tensione:.3f} V")
print(f"Corrente:  {corrente:.1f} mA")
print(f"Potenza:   {potenza:.2f} W")

# Stato batteria Li-ion 3S (soglie a riposo/carico leggero)
if tensione >= 12.0:
    stato = "PIENA"
elif tensione >= 11.1:
    stato = "BUONA"
elif tensione >= 10.5:
    stato = "DISCRETA"
elif tensione >= 9.6:
    stato = "BASSA"
else:
    stato = "CRITICA!"
print(f"Batteria:  {stato}")
```

```bash
python3 /boot/monitor_batteria.py
```

Valori misurati con RPi 4 + SDR su batteria 2S (6.3 V): circa 1.0 A, 6 W. Usa `set_calibration_32V_2A` e calcola la potenza a mano (`V × I`): il valore `power` della libreria non è affidabile con questa calibrazione.

---

## Accesso remoto Tailscale

Il codice per installare e avviare Tailscale è nel `setup_cron.sh` (punto 7). Metti la **tua** auth key (Reusable, No expiry) nella variabile `TS_AUTHKEY`.

```bash
# dal tuo Mac/PC
ssh pi@<IP-TAILSCALE-DELLA-RPI>

# sulla RPi
tailscale ip
tailscale status
```

Tailscale funziona con WiFi o SIM anche dietro il NAT dell'operatore. Dopo la sostituzione della RPi o della SD controlla nella console Tailscale che il nodo sia presente una volta sola e rimuovi quelli vecchi: l'IP del nuovo nodo può essere diverso.

---

## Configurazione SIM7080G

HAT Waveshare, SIM a 1.8 V, UART `/dev/ttyAMA0`, 115200 baud.

```bash
sudo screen /dev/ttyAMA0 115200
```

```
AT              --> OK
AT+CPIN?        --> +CPIN: READY
AT+CIMI         --> IMSI (22210... = Vodafone IT)
AT+CSQ          --> qualità segnale (99,99 = nessun segnale)
AT+CEREG?       --> registrazione (0,1 o 0,5 = registrato)
AT+CGDCONT=1,"IP","vo.vodafone.it"
AT+CFUN=1,1
```

Stato: HAT in arrivo; la connessione PPP non è ancora integrata in `setup_cron.sh`. Finché non c'è rete l'avvio procede in modalità fallback (orari fissi 16:55/17:00 UTC) e l'ATtiny, se l'orologio è perso, funziona a cicli 2 h / 30 min.

---

## Installazione e test

### Verifica DS3231

```bash
sudo modprobe i2c-dev
sudo i2cdetect -y 1                 # devono comparire 40 (INA219), 57, 68
sudo i2cget -y 1 0x68 0x02          # ore UTC (BCD)
sudo i2cget -y 1 0x68 0x01          # minuti
date -u
sudo i2cget -y 1 0x68 0x0f          # bit 7 = 0 → orologio valido
```

### Verifica crontab e log di avvio

```bash
sudo crontab -l                  # 3 righe con date -u ... shutdown
cat /tmp/setup_cron.log
sudo python3 /boot/calc_sunset.py
```

### Prova orologio perso (banco)

```bash
# 1. simula la perdita dell'ora: 00:00 e OSF=1
sudo i2cset -y 1 0x68 0x02 0x00 && sudo i2cset -y 1 0x68 0x01 0x00
sudo i2cset -y 1 0x68 0x0f 0x80
# Entro 30 s l'ATtiny deve chiudere il relè (batteria ok).
# 2. riavvia la RPi (o esegui /boot/setup_cron.sh): ora riscritta, OSF azzerato
sudo i2cget -y 1 0x68 0x0f         # → 0x00
```

### Prova tetto 19:00 CEST

Scrivi sul DS3231 le 16:58 UTC (`0x16`/`0x58`) con OSF a 0: entro 30 s dopo le 17:00 UTC il relè deve aprirsi, anche con allarme azzerato (`i2cset … 0x09 0x00`).

### Registro che sopravvive allo spegnimento

`/tmp` e `/var/log` sono in RAM (overlay) e si perdono ad ogni spegnimento. Per verificare cosa è successo il giorno prima, `calc_sunset.py` e `setup_cron.sh` scrivono in `/boot` (persistente):

```bash
cat /boot/ogn-eventi.log          # una riga per ogni avvio e per ogni shutdown (UTC), ultime 200
cat /boot/setup_cron.last.log     # log completo dell'ultimo avvio
```

Esempio: `2026-10-14 14:58:01 UTC shutdown 1458` e il giorno dopo `2026-10-15 08:03:12 UTC avvio NTP_OK=1`. I file si possono leggere anche dal Mac inserendo la SD.

### Ciclo giornaliero atteso

```
10:00 CEST  ATtiny chiude il relè, la RPi si accende, setup_cron.sh sincronizza DS3231
tramonto-90 cron: shutdown pulito (max 18:55 CEST)
tramonto-88 ATtiny apre il relè (max 19:00 CEST)
```

---

## Ripristino su nuova SD / nuova RPi

Tutto ciò che serve per ricostruire la stazione sta in **/boot**: `OGN-receiver.conf`, `config.txt`, `setup_cron.sh`, `calc_sunset.py`, `monitor_batteria.py`, `python-libs/`. Tutto il resto è in overlay e viene perso ad ogni riavvio.

### Scenario A: RPi rotta, nuova RPi + SD con immagine OGN pulita

**1. Sul Mac, scrivi l'immagine OGN sulla SD** (Raspberry Pi Imager o balenaEtcher con l'immagine scaricata dal link sopra).

**2. Estrai e rimonta la SD.** Compare il volume `boot`. Copia i tuoi file dal backup (vedi [Backup](#backup)):

```bash
cd ~/Desktop/ogn-boot-backup
cp OGN-receiver.conf setup_cron.sh calc_sunset.py monitor_batteria.py /Volumes/boot/
cp -R python-libs /Volumes/boot/
# config.txt: NON sovrascrivere se l'immagine è diversa; aggiungi solo le righe necessarie
cat >> /Volumes/boot/config.txt <<'EOT'
dtparam=i2c_arm=on
enable_uart=1
EOT
# file di servizio di macOS e fine riga Windows
dot_clean /Volumes/boot
sed -i '' 's/\r$//' /Volumes/boot/setup_cron.sh /Volumes/boot/calc_sunset.py
diskutil eject /Volumes/boot
```

Controlla in `OGN-receiver.conf` nome stazione, coordinate, WiFi e `runAtBoot="/boot/setup_cron.sh"`, e nel `setup_cron.sh` la chiave Tailscale (`TS_AUTHKEY`).

**3. Primo avvio e connessione** (la RPi deve essere collegata al WiFi o via cavo):

```bash
ping raspberrypi.local          # oppure cerca l'IP nel router
ssh-keygen -R <IP>              # se l'IP era già noto con un'altra chiave
ssh pi@<IP>                     # password: piUserPassword
```

Il primo avvio può riavviarsi da solo per l'espansione della SD (qualche minuto).

**4. Verifica configurazione** (sulla RPi):

```bash
df -h; lsblk                            # SD espansa?
overlayctl status                       # overlay attivo?
cat /tmp/setup_cron.log                 # esito dell'ultimo avvio
date; timedatectl                       # Europe/Rome, ora corretta
sudo crontab -l                         # shutdown calcolati
sudo modprobe i2c-dev; sudo i2cdetect -y 1
sudo i2cget -y 1 0x68 0x0f              # 0x00 = DS3231 sincronizzato
sudo systemctl status ogn               # OGN attivo
tailscale status                        # VPN attiva
```

**5. Se manca qualcosa:**

```bash
# a) python-libs mancanti
pip3 install --target=/home/pi/python-libs adafruit-circuitpython-ina219
sudo cp -r /home/pi/python-libs /boot/python-libs

# b) lo script non è partito: eseguilo a mano
sudo bash /boot/setup_cron.sh; cat /tmp/setup_cron.log

# c) Tailscale: vecchio nodo da rimuovere dalla console web,
#    poi riavvia con la chiave nuova in setup_cron.sh
sudo tailscale up --authkey=<LA-TUA-CHIAVE> --accept-routes
```

**6. Overlay.** Se l'immagine parte con overlay disattivato, a configurazione finita:

```bash
sudo overlayctl enable
sudo reboot
```

Per modificare file fuori da `/boot` serve `sudo overlayctl disable` + reboot; poi riattivalo.

### Scenario B: stessa RPi, SD nuova clonata da un'immagine

```bash
# sul Mac: individua la SD con diskutil list (es. /dev/disk6)
diskutil unmountDisk /dev/disk6
sudo dd if="$HOME/Desktop/ogn-backup.img" of=/dev/rdisk6 bs=4m status=progress
diskutil eject /dev/disk6
```

Con `dd` usa sempre `"$HOME"` o il percorso completo: sotto `sudo` la tilde dopo `of=` non viene espansa. La SD nuova deve avere capacità **uguale o maggiore** di quella originale.

### Scenario C: RPi diversa (es. Zero 2W al posto della 4)

Stessi passaggi dello scenario A. Con la Zero 2W:
- l'OGN usa circa l'85% della CPU, quindi lascia l'overlay attivo e non aggiungere servizi;
- il WiFi interno è quello della RPi: se in montagna non c'è rete, spegnilo per risparmiare energia (`sudo rfkill block wifi`) dopo aver verificato Tailscale via SIM;
- il consumo è sensibilmente più basso, ma controlla l'ADC dopo il cambio.

### Checklist finale dopo qualsiasi ripristino

```
[ ] SSH dal Mac funzionante           [ ] crontab con shutdown ≤ 16:55 UTC
[ ] date = Europe/Rome, NTP ok        [ ] i2cget 0x68 0x0f = 0x00
[ ] i2cdetect: 40, 57, 68             [ ] allarme 0x09/0x08 ≤ 17:00 UTC
[ ] OGN visibile su glidernet         [ ] Tailscale: nodo unico, IP annotato
[ ] overlay attivo                    [ ] password e chiavi non pubblicate
```

---

## Backup

### Solo /boot (rapido, consigliato)

```bash
# sul Mac, dalla RPi raggiunta via Tailscale o rete locale
rsync -rtv --no-perms --no-owner --no-group \
  pi@<IP>:/boot/ ~/Desktop/ogn-boot-backup/
```

`--no-perms/owner/group` evitano gli errori dovuti al filesystem FAT. Conserva il backup **fuori da GitHub** perché contiene password e chiave Tailscale.

### Immagine completa della SD

```bash
# 1. sulla RPi (opzionale, rende l'immagine più piccola dopo PiShrink)
sudo overlayctl status

# 2. sul Mac
diskutil list                                     # trova la SD, es. disk6
diskutil unmountDisk /dev/disk6
sudo dd if=/dev/rdisk6 of="$HOME/Desktop/ogn-backup.img" bs=4m status=progress
diskutil eject /dev/disk6
```

Per ridurre l'immagine usa **PiShrink su Linux** (su macOS non funziona direttamente):

```bash
wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
chmod +x pishrink.sh
sudo ./pishrink.sh -a ogn-backup.img
```

---

## Troubleshooting

### La RPi non si accende alle 10:00

```bash
sudo i2cget -y 1 0x68 0x0f         # 0x80 = orologio perso (l'ATtiny la accende comunque)
sudo i2cget -y 1 0x68 0x09         # ore taglio: deve essere > 0x08 e ≤ 0x17
sudo i2cget -y 1 0x68 0x08
```

Controlla poi: batteria sopra 10.5 V (ADC ≥ 340), relè su HIGH trigger, SDA su P0 e SCL su P3.

### Si spegne troppo presto

- Con `calc_sunset.py` v1.7.1 il fuso del demone cron non conta più (vedi sotto). Se hai una versione precedente e lo shutdown avviene 2 ore prima, il demone legge gli orari come locali: aggiorna lo script.
- Batteria sotto 9.6 V sotto carico: l'ATtiny apre il relè (protezione batteria).

### Si spegne tardi o non si spegne

- `calc_sunset.py` ancora v1.6 → sostituiscilo.
- Hai cambiato ora solare/legale senza aggiornare i tetti: vedi tabella nella sezione tetto.
- Controlla `sudo crontab -l`: devono esserci tre righe `date -u +%H%M ... shutdown` (shutdown, failsafe e tetto `1700`).

### Relè acceso 2 ore, spento 30 minuti, poi di nuovo acceso

È il ciclo "orologio perso" dello sketch: l'ATtiny vede il flag OSF del DS3231 a 1 e crede che l'ora sia persa. OSF resta a 1 finché qualcuno non lo azzera, e solo il `setup_cron.sh` v1.7 lo fa.

```bash
sudo i2cget -y 1 0x68 0x0f          # 0x80 o 0x88 = OSF a 1
cat /tmp/setup_cron.log              # se non esiste, il setup_cron.sh v1.7 non è installato
sudo i2cset -y 1 0x68 0x0f 0x00     # azzera OSF a mano
sudo i2cget -y 1 0x68 0x0f          # deve restare 0x00
```

Installa il `setup_cron.sh` v1.7 (passi nella guida SSH) così OSF viene azzerato ad ogni avvio, dopo la scrittura dell'ora.

### Accensione prima delle 10:00 dopo aver tolto l'alimentazione

Senza batteria tampone il DS3231 riparte da 00:00. L'ATtiny lo riconosce e accende la RPi subito (è il comportamento voluto): la RPi si sincronizza via NTP, riscrive l'ora e dal ciclo successivo vale l'orario normale (accensione 10:00 CEST). Succede solo dopo una perdita di alimentazione, non nel funzionamento normale.

### Lo shutdown cron parte all'ora sbagliata

Sulla RPi il demone cron può leggere gli orari del crontab in ora **locale** o in **UTC** a seconda dell'avvio (misurato: sulla stazione di prova leggeva l'ora locale, quindi `58 14 * * *` spegneva alle 14:58 CEST e non alle 16:58). Per non dipendere dal fuso, `calc_sunset.py` v1.7.1 scrive righe che scattano **ogni minuto** e confrontano `date -u`:

```
* * * * * [ "$(date -u +\%H\%M)" = "1458" ] && /sbin/shutdown -h now
```

Verifica: `sudo crontab -l` deve mostrare tre righe di questo tipo (shutdown, failsafe, tetto 1700 UTC). Per provare il fuso del demone: aggiungi due righe a un minuto preciso (una con ora locale, una con UTC) e guarda quale scatta; la procedura è nella guida SSH.

### Il relè riparte in loop dopo lo shutdown

L'allarme DS3231 non è stato scritto o è oltre il tetto. Lo sketch v1.7 lo limita a 17:00 UTC; esegui `sudo python3 /boot/calc_sunset.py` e controlla i registri 0x08/0x09.

### Batteria scarica e BMS bloccato

Il BMS 3S si blocca sotto soglia. Per sbloccarlo collega un alimentatore a circa 12–13 V (limite di corrente 0.5 A) direttamente ai terminali **del pacco/BMS**, non al sistema. Se succede spesso alza `SOGLIA_BATT_MIN`.

### DS3231 perde l'ora

Normale se manca la batteria tampone (resistenza di carica rimossa): la v1.7 lo gestisce. Per tenere l'ora anche con batteria a zero usa una **LIR2032** ricaricabile e ripristina la resistenza di carica oppure alimenta il VBAT con una batteria dedicata.

### ATtiny non comunica con il DS3231

- SDA su P0, SCL su P3 (non P2), pull-up 470 Ω su P3 verso 5 V
- Alimentazione DS3231 e BSS138 su 5 V lato HV
- `i2cdetect -y 1` deve mostrare `57` e `68`

### Relè oscilla all'avvio

Ponticello su HIGH trigger, diodo 1N5817 e 100 µF su VCC ATtiny. Con ATtiny collegato al PC via USB mentre la RPi è accesa possono avvenire reset anomali: è un problema solo da banco.

### Tailscale non si connette

Auth key scaduta o revocata: genera una nuova chiave (Reusable, No expiry), aggiornala in `TS_AUTHKEY` e riavvia. Verifica con `tailscale status`.

### INA219 non risponde

`sudo i2cdetect -y 1` deve mostrare `40`. L'INA219 va sui pin 3 e 5 della RPi a 3.3 V, non sul BSS138.

---

## Bilancio energetico

Valori **stimati**, da verificare con l'INA219.

| Voce | Valore |
|------|--------|
| Pacco 3S2P 18650 | 6.4 Ah × 11.1 V ≈ 71 Wh nominali, ~60 Wh utilizzabili fino a 9.6 V |
| RPi 4 + SDR (misurato a 6.3 V) | ~1.0 A, ~6 W |
| Consumo giornaliero estate (10:00–18:55) | ~55–60 Wh incl. perdite buck |
| Standby (ATtiny, DS3231, partitore, buck) | ~0.3 W |
| Pannello 20 W, ~5 h equivalenti di sole | ~70 Wh/giorno utili con MPPT |

Il bilancio è al limite in giornate con poco sole: l'autonomia senza sole è circa 1 giorno. Con la RPi Zero 2W il consumo si riduce sensibilmente. La stazione viene smontata d'inverno.

---

## Note finali

### Ordine di precedenza delle regole di spegnimento

1. Protezione batteria (< 9.6 V)
2. Tetto assoluto 17:00 UTC = 19:00 CEST
3. Taglio dinamico dalle effemeridi
4. Orologio perso → accensione comunque, risincronizzazione al boot

### Protezione SD

L'overlay lascia scrivibile solo `/boot`. Gli spegnimenti bruschi (taglio relè, BMS) non danneggiano la SD.

### File persistenti in /boot

- `OGN-receiver.conf`, `config.txt`
- `setup_cron.sh` (contiene la chiave Tailscale: non pubblicare!)
- `calc_sunset.py`, `monitor_batteria.py`
- `python-libs/`

### Risorse

- OGN Wiki: http://wiki.glidernet.org
- Immagine OGN: http://download.glidernet.org/seb-ogn-rpi-image
- Waveshare SIM7080G: https://www.waveshare.com/wiki/SIM7080G_Cat-M/NB-IoT_HAT
- SoftI2CMaster: https://github.com/felias-fogg/SoftI2CMaster

---

Documentazione basata su installazione reale in Umbria/Toscana, 1300 m s.l.m.  
Callsign operatore: IU6SVB · Versione 1.7 · Ottobre 2026
