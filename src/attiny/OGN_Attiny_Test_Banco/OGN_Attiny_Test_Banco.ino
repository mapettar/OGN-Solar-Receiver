// OGN Solar Receiver - ATtiny85 Digispark - TEST DA BANCO (non e lo sketch della stazione)
// Non decide nulla in base a batteria, orologio o ora: serve solo a controllare il PCB.
//
// 1) RELE: appena acceso fa 3 cicli fissi  ON 2 s / OFF 1 s su P1  (si sente il clic;
//    il LED del Digispark e quello del modulo rele seguono P1).
// 2) BUS I2C + DS3231: poi, all'infinito, controlla SDA/SCL e il DS3231 e comunica il
//    risultato con N lampeggi brevi (250 ms acceso / 250 ms spento) su P1, poi 3 s di pausa:
//      1 lampeggio  = linee alte, DS3231 risponde, orologio VALIDO (OSF = 0)
//      2 lampeggi   = linee alte, DS3231 risponde, orologio PERSO  (OSF = 1)
//      3 lampeggi   = linee alte, ma il DS3231 NON risponde
//      4 lampeggi   = solo SDA (P0) letta a livello basso
//      5 lampeggi   = solo SCL (P3) letta a livello basso
//      6 lampeggi   = SDA e SCL entrambe lette a livello basso
// Nota: dopo l'accensione il bootloader del Digispark attende circa 5 s prima di partire.
// Se il rele fa "ratatatata" con i lampeggi e ti disturba, scollega il filo IN: il LED
// del Digispark basta per leggere il codice.
// Stessi pin dello sketch della stazione: P0 = SDA, P3 = SCL, P1 = rele.

#define SDA_PORT PORTB
#define SDA_PIN 0      // P0 = SDA
#define SCL_PORT PORTB
#define SCL_PIN 3      // P3 = SCL (NON usare P2)

#include <SoftI2CMaster.h>

#define DS3231_ADDR   0x68
#define RELAY_PIN     1      // P1 = rele (HIGH = acceso con jumper su HIGH)
#define SDA_PIN_NUM   0
#define SCL_PIN_NUM   3

// ==== INIZIO LOGICA PURA ====
// Codice dei lampeggi dal risultato del test.
// sdaAlta/sclAlta: livello letto sulle linee a riposo. risponde: il DS3231 ha dato ACK
// e la lettura e riuscita. status: registro 0x0F (bit 7 = OSF, orologio perso).
uint8_t codiceTest(bool sdaAlta, bool sclAlta, bool risponde, uint8_t status) {
  if (!sdaAlta && !sclAlta) return 6;
  if (!sdaAlta) return 4;
  if (!sclAlta) return 5;
  if (!risponde) return 3;
  return (status & 0x80) ? 2 : 1;
}
// ==== FINE LOGICA PURA ====

bool leggiStatus(uint8_t *st) {
  if (!i2c_start((DS3231_ADDR << 1) | I2C_WRITE)) { i2c_stop(); return false; }
  i2c_write(0x0F);
  i2c_stop();
  if (!i2c_start((DS3231_ADDR << 1) | I2C_READ)) { i2c_stop(); return false; }
  *st = i2c_read(true);
  i2c_stop();
  return true;
}

void rele(bool acceso) {
  digitalWrite(RELAY_PIN, acceso ? HIGH : LOW);
}

void lampeggia(uint8_t n) {
  for (uint8_t i = 0; i < n; i++) {
    rele(true);  delay(250);
    rele(false); delay(250);
  }
}

void setup() {
  pinMode(RELAY_PIN, OUTPUT);
  rele(false);
  delay(500);
  // 1) Prova del rele: 3 cicli ON 2 s / OFF 1 s
  for (uint8_t i = 0; i < 3; i++) {
    rele(true);  delay(2000);
    rele(false); delay(1000);
  }
  delay(2000);
}

void loop() {
  // Livelli a riposo, prima di toccare il bus (le pull-up stanno sul modulo DS3231)
  pinMode(SDA_PIN_NUM, INPUT);
  pinMode(SCL_PIN_NUM, INPUT);
  delay(50);
  bool sdaAlta = digitalRead(SDA_PIN_NUM) == HIGH;
  bool sclAlta = digitalRead(SCL_PIN_NUM) == HIGH;

  bool risponde = false;
  uint8_t status = 0;
  if (sdaAlta && sclAlta) {
    i2c_init();
    risponde = leggiStatus(&status);
  }

  lampeggia(codiceTest(sdaAlta, sclAlta, risponde, status));
  delay(3000);
}
