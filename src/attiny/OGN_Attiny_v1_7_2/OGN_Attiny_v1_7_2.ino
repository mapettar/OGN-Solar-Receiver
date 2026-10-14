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
