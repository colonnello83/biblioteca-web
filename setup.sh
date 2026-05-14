#!/bin/bash

echo "========================================"
echo "  BIBLIOTECA WEB 4.0 — Setup automatico"
echo "  Raspberry Pi 3"
echo "========================================"
echo ""

# ── PARAMETRI PERSONALIZZATI ──────────────────
echo "Inserisci i parametri di configurazione:"
echo ""
read -p "IP o host FTP del NAS                                      : " FTP_HOST
read -p "Utente FTP                                                  : " FTP_USER
read -s -p "Password FTP                                               : " FTP_PASS
echo ""
read -p "Percorso file Excel sul NAS (es. /disk1/Buffalo/libri/libri.xlsx) : " FTP_PATH
read -p "IP Arduino Mega2560                                         : " ARDUINO_IP
read -p "Porta TCP Arduino (es. 5000)                                : " ARDUINO_PORT
read -p "Porta server web (premi Invio per default 3000)             : " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-3000}

echo ""
echo "Parametri acquisiti. Avvio installazione..."
echo ""

# ── AGGIORNAMENTO SISTEMA ─────────────────────
echo "[1/6] Aggiornamento sistema..."
sudo apt update -y && sudo apt upgrade -y

# ── NODE.JS 20 LTS ────────────────────────────
echo "[2/6] Installazione Node.js 20 LTS..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

echo "Node.js: $(node -v)"
echo "npm: $(npm -v)"

# ── CARTELLE E PROGETTO ───────────────────────
echo "[3/6] Creazione struttura progetto..."
mkdir -p ~/biblioteca-web/public
cd ~/biblioteca-web

cat > ~/biblioteca-web/package.json << 'PKGEOF'
{
  "name": "biblioteca-web",
  "version": "1.0.0",
  "type": "module",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  }
}
PKGEOF

npm install express basic-ftp xlsx
npm install --save-dev nodemon

# ── SERVER.JS ─────────────────────────────────
echo "[4/6] Scrittura server.js..."
cat > ~/biblioteca-web/server.js << SERVEREOF
import express from "express";
import ftp from "basic-ftp";
import net from "net";
import path from 'path';
import { fileURLToPath } from 'url';
import xlsx from "xlsx";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const app = express();
const PORT = ${SERVER_PORT};
const HOST = "0.0.0.0";

const FTP_CONFIG = {
  host: "${FTP_HOST}",
  user: "${FTP_USER}",
  password: "${FTP_PASS}",
  secure: false,
  path: "${FTP_PATH}"
};

const MEGA_CONFIG = {
  host: "${ARDUINO_IP}",
  port: ${ARDUINO_PORT}
};

const LOCAL_XLSX = path.join(__dirname, 'libri.xlsx');
let libri = [];

function leggiExcel(percorso) {
  try {
    const workbook = xlsx.readFile(percorso);
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    const records = xlsx.utils.sheet_to_json(sheet, { header: 1 });
    libri = records
      .map(riga => ({
        autore:  String(riga[0] || "").trim(),
        titolo:  String(riga[1] || "").trim(),
        editore: String(riga[2] || "").trim(),
        genere:  String(riga[3] || "").trim(),
        codice:  String(riga[4] || "").trim()
      }))
      .filter(b => b.autore && b.titolo);
    console.log("Excel caricato (" + libri.length + " libri)");
  } catch (err) {
    console.error("Errore lettura Excel:", err);
  }
}

function raggruppaPerGenere() {
  const generi = {};
  for (const libro of libri) {
    const genere = libro.genere ? libro.genere.trim() : 'Senza Genere';
    if (!generi[genere]) {
      generi[genere] = { genere: genere, codici: new Set(), libri: 0 };
    }
    if (libro.codice) {
      generi[genere].codici.add(libro.codice.trim());
    }
    generi[genere].libri++;
  }
  return Object.values(generi).map(g => ({
    genere: g.genere,
    codici: Array.from(g.codici).filter(c => c).join(','),
    libri: g.libri
  }));
}

async function scaricaExcel() {
  const client = new ftp.Client();
  client.ftp.verbose = false;
  try {
    console.log("Connessione FTP in corso...");
    await client.access({
      host: FTP_CONFIG.host,
      user: FTP_CONFIG.user,
      password: FTP_CONFIG.password,
      secure: FTP_CONFIG.secure
    });
    await client.downloadTo(LOCAL_XLSX, FTP_CONFIG.path);
    console.log("Excel scaricato");
    leggiExcel(LOCAL_XLSX);
  } catch (err) {
    console.error("Errore FTP:", err);
  } finally {
    client.close();
  }
}

async function inviaCodiceTCP(codice) {
  return new Promise((resolve, reject) => {
    const client = new net.Socket();
    client.connect(MEGA_CONFIG.port, MEGA_CONFIG.host, () => {
      client.write(codice.toString());
      console.log("Codice inviato al Mega: " + codice);
      client.end();
      resolve();
    });
    client.on("error", (err) => {
      console.error("Errore connessione TCP:", err.message);
      reject(err);
    });
  });
}

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.get("/api/libri", (req, res) => res.json(libri));
app.get("/api/generi", (req, res) => res.json(raggruppaPerGenere()));

app.post("/api/invia", async (req, res) => {
  const { codice } = req.body;
  if (!codice) return res.status(400).json({ error: "Codice mancante" });
  try {
    await inviaCodiceTCP(codice);
    res.json({ success: true });
  } catch {
    res.status(500).json({ success: false });
  }
});

app.post("/api/aggiorna", async (req, res) => {
  await scaricaExcel();
  res.json({ success: true, libri: libri.length });
});

app.get("/api/test", async (req, res) => {
  const codice = req.query.codice || "99";
  try {
    await inviaCodiceTCP(codice);
    res.json({ success: true, codice });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.listen(PORT, HOST, async () => {
  console.log("Server avviato su http://" + HOST + ":" + PORT);
  await scaricaExcel();
  setInterval(() => {}, 1000);
});
SERVEREOF

# ── PUBLIC/INDEX.HTML ─────────────────────────
echo "[5/6] Scrittura file frontend..."
cat > ~/biblioteca-web/public/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Biblioteca 4.0</title>
  <link rel="icon" type="image/png" href="app_icon.png">
  <link rel="apple-touch-icon" href="app_icon.png">
  <meta name="theme-color" content="#ffffff">
  <link rel="stylesheet" href="style.css" />
</head>
<body>
  <header>
    <h1>Biblioteca 4.0</h1>
    <div class="buttons">
      <button id="onall">ON ALL</button>
      <button id="offall">OFF</button>
      <button id="aggiorna">Aggiorna Elenco</button>
      <button id="btn-generi" class="nav-button">Generi</button>
      <button id="btn-titoli" class="nav-button" style="display:none;">Titoli</button>
    </div>
    <input type="text" id="search" placeholder="Cerca per autore, titolo o genere..." />
  </header>
  <main id="main-container">
    <div id="libri-container">
      <p>Caricamento in corso...</p>
    </div>
    <div id="generi-container" style="display:none;"></div>
  </main>
  <script src="app.js"></script>
</body>
</html>
HTMLEOF

# ── PUBLIC/STYLE.CSS ──────────────────────────
cat > ~/biblioteca-web/public/style.css << 'CSSEOF'
body {
  font-family: Arial, sans-serif;
  background: #f5f7fa;
  margin: 0;
  padding: 0;
  color: #222;
}

header {
  text-align: center;
  background: #004a9f;
  color: white;
  padding: 1rem;
}

header h1 {
  margin: 0.2rem 0;
}

.buttons {
  margin: 0.5rem 0;
}

button {
  background: #0078ff;
  border: none;
  color: white;
  padding: 0.5rem 1rem;
  margin: 0.2rem;
  border-radius: 6px;
  cursor: pointer;
}

button:hover {
  background: #005fcc;
}

#search {
  width: 80%;
  max-width: 400px;
  padding: 0.5rem;
  border-radius: 6px;
  border: 1px solid #ccc;
  display: block;
  margin-left: auto;
  margin-right: auto;
  margin-top: 1rem;
  margin-bottom: 1rem;
}

#libri-container {
  padding: 1rem;
}

.libro-btn {
  display: block;
  width: 98%;
  max-width: 600px;
  margin-left: auto;
  margin-right: auto;
  text-align: center;
  background: white;
  border: 1px solid #ddd;
  border-radius: 8px;
  margin-bottom: 0.5rem;
  padding: 0.5rem 1rem;
}

.libro-btn:hover {
  background: #eef3ff;
}

.autore {
  font-size: 0.9rem;
  color: #555;
}

.titolo {
  font-size: 1.0rem;
  color: #12501A;
}

.dettagli {
  font-size: 0.85rem;
  color: #777;
}
CSSEOF

# ── PUBLIC/APP.JS ─────────────────────────────
cat > ~/biblioteca-web/public/app.js << 'APPEOF'
const searchInput = document.getElementById("search");
const onAllBtn = document.getElementById("onall");
const offAllBtn = document.getElementById("offall");
const aggiornaBtn = document.getElementById("aggiorna");
const libriContainer = document.getElementById('libri-container');
const generiContainer = document.getElementById('generi-container');
const btnGeneri = document.getElementById('btn-generi');
const btnTitoli = document.getElementById('btn-titoli');

let libri = [];

async function fetchAndRender(view = 'libri') {
  const endpoint = view === 'libri' ? "/api/libri" : "/api/generi";
  libriContainer.innerHTML = view === 'libri' ? '<p>Caricamento in corso...</p>' : '';
  generiContainer.innerHTML = view === 'generi' ? '<p>Caricamento in corso...</p>' : '';
  try {
    const response = await fetch(endpoint);
    const dati = await response.json();
    libri = dati;
    if (view === 'libri') {
      if (!dati.length) {
        libriContainer.innerHTML = "<p>Nessun libro trovato.</p>";
      } else {
        libriContainer.innerHTML = "";
        dati.forEach(libro => {
          const btn = document.createElement("button");
          btn.className = "libro-btn";
          btn.innerHTML = `
            <div class="autore">${libro.autore}</div>
            <div class="titolo"><strong>${libro.titolo}</strong></div>
            <div class="dettagli">${libro.editore} · ${libro.genere}</div>
          `;
          btn.onclick = () => inviaCodici(libro.codice);
          libriContainer.appendChild(btn);
        });
      }
      searchInput.style.display = 'block';
    } else {
      renderGeneri(dati);
      searchInput.style.display = 'none';
    }
    libriContainer.style.display = view === 'libri' ? 'block' : 'none';
    generiContainer.style.display = view === 'generi' ? 'block' : 'none';
    btnGeneri.style.display = view === 'libri' ? 'inline-block' : 'none';
    btnTitoli.style.display = view === 'generi' ? 'inline-block' : 'none';
  } catch (error) {
    libriContainer.innerHTML = `<p>Errore nel caricamento.</p>`;
    console.error("Errore nel fetching:", error);
  }
}

function renderGenere(genereData) {
  const btn = document.createElement('button');
  btn.className = 'libro-btn';
  btn.innerHTML = `
    <div class="titolo"><strong>${genereData.genere}</strong></div>
    <div class="dettagli">Libri nel genere: ${genereData.libri}</div>
  `;
  btn.onclick = () => inviaCodici(genereData.codici);
  return btn;
}

function renderGeneri(generi) {
  generiContainer.innerHTML = '';
  generi.forEach(genereData => {
    generiContainer.appendChild(renderGenere(genereData));
  });
}

async function inviaCodici(codiciStringa) {
  const codici = codiciStringa.split(',').map(c => c.trim()).filter(c => c);
  let successCount = 0;
  if (codici.length === 0) {
    alert('Attenzione: Nessun codice valido da inviare.');
    return;
  }
  for (const codice of codici) {
    try {
      const response = await fetch('/api/invia', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ codice: codice })
      });
      if (response.ok) successCount++;
    } catch (error) {
      console.error('Errore di rete durante l\'invio:', error);
    }
  }
  if (codici.length > 1) {
    if (successCount === codici.length) {
      alert(`Invio completato: ${successCount} codici inviati con successo.`);
    } else {
      alert(`Attenzione: Inviati ${successCount} codici su ${codici.length}.`);
    }
  }
}

searchInput.addEventListener("input", e => {
  const q = e.target.value.toLowerCase();
  const filtrati = libri.filter(l =>
    l.autore.toLowerCase().includes(q) ||
    l.titolo.toLowerCase().includes(q) ||
    l.genere.toLowerCase().includes(q)
  );
  libriContainer.innerHTML = "";
  if (!filtrati.length) {
    libriContainer.innerHTML = "<p>Nessun libro trovato.</p>";
    return;
  }
  filtrati.forEach(libro => {
    const btn = document.createElement("button");
    btn.className = "libro-btn";
    btn.innerHTML = `
      <div class="autore">${libro.autore}</div>
      <div class="titolo"><strong>${libro.titolo}</strong></div>
      <div class="dettagli">${libro.editore} · ${libro.genere}</div>
    `;
    btn.onclick = () => inviaCodici(libro.codice);
    libriContainer.appendChild(btn);
  });
});

async function aggiornaCSV() {
  try {
    const res = await fetch("/api/aggiorna", { method: "POST" });
    const data = await res.json();
    alert(`Aggiornato: ${data.libri} libri caricati`);
    const currentView = btnGeneri.style.display !== 'none' ? 'libri' : 'generi';
    fetchAndRender(currentView);
  } catch {
    alert("Errore durante aggiornamento");
  }
}

btnGeneri.addEventListener('click', () => fetchAndRender('generi'));
btnTitoli.addEventListener('click', () => fetchAndRender('libri'));
onAllBtn.onclick = () => inviaCodici("ONALL");
offAllBtn.onclick = () => inviaCodici("OFF");
aggiornaBtn.onclick = aggiornaCSV;

fetchAndRender('libri');
APPEOF

# ── SERVICE SYSTEMD ───────────────────────────
echo "[6/6] Configurazione avvio automatico (systemd)..."
sudo bash -c "cat > /etc/systemd/system/biblioteca-web.service << 'SVCEOF'
[Unit]
Description=Biblioteca Web Server
After=network.target

[Service]
ExecStart=/usr/bin/node /home/colonnello/biblioteca-web/server.js
Type=simple
Restart=always
User=colonnello

[Install]
WantedBy=multi-user.target
SVCEOF"

sudo systemctl daemon-reload
sudo systemctl enable biblioteca-web.service
sudo systemctl start biblioteca-web.service

# ── FINE ──────────────────────────────────────
echo ""
echo "========================================"
echo "  Installazione completata!"
echo ""
echo "  Accedi all'app dal browser:"
echo "  http://$(hostname -I | awk '{print $1}'):${SERVER_PORT}"
echo ""
echo "  Comandi utili:"
echo "  sudo systemctl status biblioteca-web"
echo "  sudo systemctl restart biblioteca-web"
echo "  sudo journalctl -u biblioteca-web -f"
echo "========================================"
