// OGN Solar Receiver - ATtiny85 Digispark - v1.7.4 (soglie batteria tarate sulle misure)
// - Novita v1.7.4: SOGLIA_BATT_MIN 295 (~9,6 V) e SOGLIA_BATT_ON 332 (~10,8 V). Le soglie
//   310 / 340 della v1.7.3 erano calcolate con il partitore nominale (rapporto 0,1515, VCC 4,8 V),
//   ma sul Digispark reale il rapporto e 0,143 e VCC 4,75 V: valevano ~10,1 V e ~11,1 V.
//   Il 17 nov 2026 la stazione non e ripartita al mattino con il pacco a ~10,85 V a riposo
//   (sotto i ~11,1 V di riavvio) ed e ripartita solo quando la carica dal banco ha alzato la tensione.
//   Logica, orari e silenzio I2C identici alla v1.7.3.
// - Novita v1.7.3: negli ultimi 3 minuti prima del taglio del rele l'ATtiny NON
//   tocca piu il bus I2C. Una RPi in halt si risveglia se SCL (GPIO3) viene tirato
//   a massa: le letture del DS3231 ogni 30 s la riaccendevano dopo ~45 s e il rele
//   la tagliava a meta avvio. Ora aspetta l'istante del taglio senza I2C (la
//   protezione batteria resta attiva) e apre il rele all'ora esatta.
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

// ---- Soglie ADC batteria 3S Li-ion (R1=56k, R2=10k, VCC ATtiny ~4.75V) ----
// Taratura MISURATA il 17 nov 2026 (pacco 10,9 V dal INA219): P4 = 1,555 V (rapporto 0,1427, non il
// nominale 0,1515: la linea USB con zener del Digispark carica il partitore) e VCC = 4,75 V.
//   conteggi = Vbatt * rapporto / VCC * 1023  ->  ~30,7 conteggi per volt
// Con 310 / 340 (v1.7.3) le soglie reali erano ~10,09 V / ~11,07 V; misure del 30 ott 2026
// (12,26 V sul pacco, rapporto 0,1403, VCC 4,79 V) davano ~10,35 V / ~11,35 V.
// Il rapporto sembra calare un po' con la tensione (0,1427 a 10,9 V, 0,1403 a 12,26 V; causa probabile: leakage
// dello zener da 3,6 V): tara vicino alla soglia che ti interessa.
// ATTENZIONE: i conteggi dipendono da VCC (riferimento dell'ADC): +/-0,1 V su VCC spostano le soglie di ~0,2 V.
// Per ricalcolare sul proprio esemplare: misura Vbatt (INA219), P4 e VCC con lo stesso tester.
//   conteggi_per_volt = 1023 * (P4 / Vbatt) / VCC;   soglia = V desiderata * conteggi_per_volt
#define SOGLIA_BATT_MIN      295    // ~9,6 V  spegne (BMS interviene piu in basso)
#define SOGLIA_BATT_ON       332    // ~10,8 V riaccende

// ---- Orologio non valido: cicli ON/OFF finche la RPi non riscrive l'ora ----
#define INVALIDO_ON_MS       7200000UL   // 2 h acceso
#define INVALIDO_OFF_MS      1800000UL   // 30 min spento
#define FINESTRA_BOOT_MS     300000UL    // 00:00-00:04 dopo il boot ATtiny = ora persa

// ---- Silenzio I2C prima del taglio ----
// La RPi si ferma 2 min prima del taglio (tramonto-90 / tramonto-88): partire da 3 min
// lascia 1 min di margine prima dell'halt. L'ultima lettura cade 150-180 s prima.
#define PRE_TAGLIO_S         180L        // secondi di silenzio I2C prima del taglio
#define DOPO_TAGLIO_MS       60000UL     // pausa dopo il taglio (evita di riaccendere per l'arrotondamento al minuto)

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

// Secondi che mancano al taglio (negativo se gia passato)
long secondiAlTaglio(uint16_t taglioMin, uint8_t ore, uint8_t minuti, uint8_t sec) {
  long adesso = ((long)ore * 60 + minuti) * 60 + sec;
  return (long)taglioMin * 60 - adesso;
}

// Siamo negli ultimi PRE_TAGLIO_S secondi prima del taglio, con rele acceso e orologio valido?
// In quel caso si aspetta senza I2C fino all'istante del taglio.
bool inSilenzioPreTaglio(bool releAcceso, bool perso, uint16_t adessoMin,
                         uint16_t taglioMin, long secMancanti) {
  return releAcceso && !perso && inFinestra(adessoMin, taglioMin) &&
         secMancanti > 0 && secMancanti <= PRE_TAGLIO_S;
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

// Attende 'ms' millisecondi SENZA toccare il bus I2C (la RPi in halt si sveglierebbe).
// Controlla la batteria ogni secondo: se cala sotto la soglia esce subito.
void attendiSenzaI2C(unsigned long ms) {
  unsigned long t0 = millis();
  for (;;) {
    unsigned long trascorso = millis() - t0;
    if (trascorso >= ms) return;
    unsigned long resto = ms - trascorso;
    delay(resto < 1000UL ? resto : 1000UL);
    if (leggiADC() < SOGLIA_BATT_MIN) return;
  }
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

  bool bcdOk = bcdValido(ora[0]) && bcdValido(ora[1]) && bcdValido(ora[2]);   // solo l'ora: un allarme sporco non rende perso l'orologio

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
  uint8_t sec = bcd2dec(ora[0] & 0x7F);
  bool perso = orologioPerso(erroriI2C < 3, st, ore, minuti, millis());

  uint8_t oreAl = bcd2dec(al[2] & 0x3F);
  uint8_t minAl = bcd2dec(al[1] & 0x7F);
  uint16_t taglio = calcolaTaglio(oreAl, minAl);
  uint16_t adesso = (uint16_t)ore * 60 + minuti;

  // Ultimi minuti prima del taglio: niente I2C fino all'istante del taglio, poi apre il rele.
  long mancano = secondiAlTaglio(taglio, ore, minuti, sec);
  if (inSilenzioPreTaglio(statoRele, perso, adesso, taglio, mancano)) {
    attendiSenzaI2C((unsigned long)mancano * 1000UL);
    impostaRele(false);
    delay(DOPO_TAGLIO_MS);
    return;
  }

  int adc = leggiADC();
  impostaRele(vuoleRele(statoRele, perso, adesso, taglio, adc, millis() - tCambio));

  delay(30000);   // controlla ogni 30 secondi
}
