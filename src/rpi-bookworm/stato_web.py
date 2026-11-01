#!/usr/bin/env python3
"""stato_web.py v1.0 - trasforma l'output di `stato` in una pagina HTML statica.

Lo lancia il cron ogni 10 minuti (come root); la pagina la serve ogn-stato-web.service
(python3 -m http.server, porta 8090). Nessuna libreria, nessun JavaScript.

Uso:  python3 stato_web.py [--out CARTELLA]      (default /var/lib/ogn-stato)
Prove: STATO_CMD="bash /percorso/stato_stazione.sh" python3 stato_web.py --out /tmp/prova
"""
import html
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

OUT = "/var/lib/ogn-stato"
CMD = os.environ.get("STATO_CMD", "bash /usr/local/sbin/stato_stazione.sh")

CSS = """
:root{--bg:#f4f5f7;--card:#fff;--ink:#1d2330;--mut:#66708a;--line:#dfe3ec;--ok:#1b7f4b;--okbg:#e4f4ea;--bad:#b3261e;--badbg:#fbe7e5}
@media (prefers-color-scheme:dark){:root{--bg:#12151c;--card:#1b2030;--ink:#e6e9f2;--mut:#98a2bd;--line:#2a3045;--ok:#6fd49b;--okbg:#17352a;--bad:#ff8a80;--badbg:#3d1d1b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:760px;margin:0 auto;padding:16px}
h1{font-size:1.2rem;margin:0 0 4px}
.sub{color:var(--mut);font-size:.9rem;margin:0 0 14px}
.verdetto{border-radius:12px;padding:14px 16px;font-weight:600;margin:0 0 14px}
.verdetto.ok{background:var(--okbg);color:var(--ok)}
.verdetto.bad{background:var(--badbg);color:var(--bad)}
section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 16px;margin:0 0 12px}
h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:0 0 8px}
.r{margin:4px 0;overflow-wrap:anywhere}
.r.i{color:var(--mut);font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.85rem;white-space:pre-wrap}
.tag{display:inline-block;min-width:2.6em;text-align:center;border-radius:6px;padding:0 6px;margin-right:8px;font-size:.8rem;font-weight:700}
.r.ok .tag{background:var(--okbg);color:var(--ok)}
.r.bad .tag{background:var(--badbg);color:var(--bad)}
.r.bad{font-weight:600}
a{color:var(--mut)}
"""


def esegui():
    try:
        p = subprocess.run(shlex.split(CMD), capture_output=True, text=True, timeout=90)
        return p.stdout or p.stderr or "(nessun output)"
    except Exception as e:  # noqa: BLE001 - la pagina deve comunque uscire
        return "STATO STAZIONE - errore\n\n== Verdetto ==\n  [!!] impossibile eseguire stato: %s\n" % e


def analizza(testo):
    titolo = ""
    sezioni = []          # [(nome, [(tipo, testo)])]
    for riga in testo.splitlines():
        if not riga.strip():
            continue
        m = re.match(r"^==\s*(.*?)\s*==\s*$", riga)
        if m:
            sezioni.append((m.group(1), []))
        elif not sezioni:
            titolo = titolo or riga.strip()
        else:
            s = riga.strip()
            if s.startswith("[OK]"):
                sezioni[-1][1].append(("ok", s[4:].strip()))
            elif s.startswith("[!!]"):
                sezioni[-1][1].append(("bad", s[4:].strip()))
            else:
                sezioni[-1][1].append(("i", riga.rstrip().lstrip()))
    return titolo, sezioni


def pagina(testo):
    titolo, sezioni = analizza(testo)
    problemi = sum(1 for _, righe in sezioni for t, _ in righe if t == "bad")
    verdetto = [r for n, righe in sezioni if n == "Verdetto" for _, r in righe]
    esito = verdetto[0] if verdetto else "nessun verdetto"
    classe = "ok" if problemi == 0 and "TUTTO OK" in esito else "bad"
    adesso = time.strftime("%d/%m/%Y %H:%M:%S")
    out = ['<!doctype html><html lang="it"><head><meta charset="utf-8">',
           '<meta name="viewport" content="width=device-width,initial-scale=1">',
           '<meta http-equiv="refresh" content="120">',
           "<title>Stato stazione OGN</title><style>%s</style></head><body><main>" % CSS,
           "<h1>Stato stazione OGN</h1>",
           '<p class="sub">%s<br>Pagina aggiornata il %s (si rigenera ogni 10 minuti, solo con la Pi accesa)</p>'
           % (html.escape(titolo), adesso),
           '<div class="verdetto %s">%s</div>' % (classe, html.escape(esito))]
    for nome, righe in sezioni:
        if nome == "Verdetto":
            continue
        out.append("<section><h2>%s</h2>" % html.escape(nome))
        for tipo, t in righe:
            if tipo == "i":
                out.append('<div class="r i">%s</div>' % html.escape(t))
            else:
                out.append('<div class="r %s"><span class="tag">%s</span>%s</div>'
                           % (tipo, "OK" if tipo == "ok" else "!!", html.escape(t)))
        out.append("</section>")
    out.append("</main></body></html>")
    return "\n".join(out)


def scrivi(percorso, contenuto):
    d = os.path.dirname(percorso)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(contenuto)
    os.chmod(tmp, 0o644)
    os.replace(tmp, percorso)      # sostituzione atomica: il server non legge mai mezza pagina


def main():
    out = OUT
    if "--out" in sys.argv:
        i = sys.argv.index("--out")
        try:
            out = sys.argv[i + 1]
        except IndexError:
            sys.exit("--out vuole una cartella")
    os.makedirs(out, exist_ok=True)
    os.chmod(out, 0o755)
    testo = esegui()
    scrivi(os.path.join(out, "index.html"), pagina(testo))
    scrivi(os.path.join(out, "stato.txt"), testo)


if __name__ == "__main__":
    main()
