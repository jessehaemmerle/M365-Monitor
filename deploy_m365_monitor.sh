#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/m365-monitor"
RUN_USER="${SUDO_USER:-$(whoami)}"
PORT="8000"
WITH_NGINX=0
SRC_DIR=""
ENV_FILE="/etc/m365-monitor.env"

usage() {
  cat <<'USAGE'
Usage: sudo ./deploy_m365_monitor.sh [options]

Options:
  --app-dir PATH        Zielverzeichnis (Default: /opt/m365-monitor)
  --user USER           Linux-User für den Service (Default: $SUDO_USER oder aktueller User)
  --port PORT           Uvicorn-Port (Default: 8000, lauscht auf 127.0.0.1)
  --src PATH            Pfad zum entpackten M365-Monitor-Projekt (Ordner mit backend/ und frontend/)
  --env-file PATH       Pfad zu bereits existierender .env (TENANT_ID, CLIENT_ID, CLIENT_SECRET, ALLOWED_ORIGINS)
  --with-nginx          Nginx vHost erzeugen (static frontend + /api Proxy)
  --domain NAME         Domain für Nginx-Server (z. B. monitor.example.com)
  -h, --help            Hilfe

Beispiel:
  sudo ./deploy_m365_monitor.sh --src ./M365-Monitor --with-nginx --domain monitor.example.com
USAGE
}

DOMAIN=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir) APP_DIR="$2"; shift 2;;
    --user) RUN_USER="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --src) SRC_DIR="$2"; shift 2;;
    --env-file) ENV_FILE="$2"; shift 2;;
    --with-nginx) WITH_NGINX=1; shift 1;;
    --domain) DOMAIN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root oder via sudo ausführen."
  exit 1
fi

if [[ -z "${SRC_DIR}" ]]; then
  # Wenn kein --src angegeben wurde, prüfen wir, ob wir im Projektordner sind.
  if [[ -d "backend" && -d "frontend" ]]; then
    SRC_DIR="$(pwd)"
  else
    echo "Fehler: --src nicht angegeben und kein backend/frontend im aktuellen Verzeichnis gefunden."
    exit 1
  fi
fi

if [[ ! -d "${SRC_DIR}/backend" || ! -f "${SRC_DIR}/backend/app.py" ]]; then
  echo "Fehler: ${SRC_DIR} sieht nicht wie das Projekt-Root aus (backend/app.py fehlt)."
  exit 1
fi
if [[ ! -d "${SRC_DIR}/frontend" || ! -f "${SRC_DIR}/frontend/index.html" ]]; then
  echo "Fehler: ${SRC_DIR} enthält kein frontend/index.html."
  exit 1
fi

echo "==> Ziel: ${APP_DIR}  (User: ${RUN_USER}, Port: ${PORT})"

# --- Helpers ---
ensure_pkg() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$pkg"
  else
    echo "Hinweis: Paketmanager nicht erkannt. Bitte installieren Sie manuell: $pkg"
  fi
}

# --- Systemabhängige Tools ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python3 fehlt. Installation..."
  ensure_pkg python3
fi
if ! python3 -m venv --help >/dev/null 2>&1; then
  echo "python3-venv fehlt. Installation..."
  ensure_pkg python3-venv
fi
if ! command -v pip3 >/dev/null 2>&1; then
  echo "pip3 fehlt. Installation..."
  ensure_pkg python3-pip
fi

# --- App-Verzeichnis vorbereiten ---
mkdir -p "${APP_DIR}"
rsync -a --delete "${SRC_DIR}/backend/" "${APP_DIR}/backend/"
rsync -a --delete "${SRC_DIR}/frontend/" "${APP_DIR}/frontend/"
chown -R "${RUN_USER}:${RUN_USER}" "${APP_DIR}"

# --- Python venv + Dependencies ---
if [[ ! -d "${APP_DIR}/.venv" ]]; then
  echo "==> Erstelle venv in ${APP_DIR}/.venv"
  sudo -u "${RUN_USER}" python3 -m venv "${APP_DIR}/.venv"
fi
echo "==> Installiere Python-Dependencies"
sudo -u "${RUN_USER}" bash -c "source '${APP_DIR}/.venv/bin/activate' && pip install --upgrade pip && pip install -r '${APP_DIR}/backend/requirements.txt'"

# --- Environment Datei ---
if [[ "${ENV_FILE}" == "/etc/m365-monitor.env" && ! -f "${ENV_FILE}" ]]; then
  # Falls es eine .env im Projekt gibt, diese als Vorlage nehmen
  if [[ -f "${SRC_DIR}/backend/.env" ]]; then
    cp "${SRC_DIR}/backend/.env" "${ENV_FILE}"
  elif [[ -f "${SRC_DIR}/backend/.env.example" ]]; then
    cp "${SRC_DIR}/backend/.env.example" "${ENV_FILE}"
  else
    touch "${ENV_FILE}"
  fi
fi

# Sicherstellen, dass Pflichtvariablen gesetzt sind
ensure_env_var() {
  local key="$1"
  local default="$2"
  if ! grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    read -r -p "Bitte Wert für ${key} eingeben ${default:+(${default})}: " val
    val="${val:-$default}"
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

ensure_env_var "TENANT_ID" ""
ensure_env_var "CLIENT_ID" ""
ensure_env_var "CLIENT_SECRET" ""
# Port und Allowed Origins ergänzen/aktualisieren
if grep -qE "^PORT=" "${ENV_FILE}"; then
  sed -i "s/^PORT=.*/PORT=${PORT}/" "${ENV_FILE}"
else
  echo "PORT=${PORT}" >> "${ENV_FILE}"
fi

if [[ -n "${DOMAIN}" ]]; then
  ALLOWED="https://${DOMAIN},http://localhost:5500"
else
  ALLOWED="*"
fi
if grep -qE "^ALLOWED_ORIGINS=" "${ENV_FILE}"; then
  sed -i "s|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=${ALLOWED}|" "${ENV_FILE}"
else
  echo "ALLOWED_ORIGINS=${ALLOWED}" >> "${ENV_FILE}"
fi

chmod 640 "${ENV_FILE}"
chown root:"${RUN_USER}" "${ENV_FILE}" || true

# --- systemd Service ---
SERVICE_FILE="/etc/systemd/system/m365-monitor.service"
cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=M365-Monitor FastAPI
After=network.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/.venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port \${PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now m365-monitor.service

echo "==> Service-Status:"
systemctl --no-pager --full status m365-monitor.service || true

# --- Optional: Nginx-Konfiguration ---
if [[ "${WITH_NGINX}" -eq 1 ]]; then
  if ! command -v nginx >/dev/null 2>&1; then
    echo "Nginx ist nicht installiert. Installation..."
    ensure_pkg nginx
  fi
  if [[ -z "${DOMAIN}" ]]; then
    echo "Warnung: --with-nginx gesetzt, aber keine --domain angegeben. Nginx-Konfiguration wird für _ statt Domain erstellt."
  fi
  NCONF="/etc/nginx/sites-available/m365-monitor.conf"
  cat > "${NCONF}" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN:-_};

    root ${APP_DIR}/frontend;
    index index.html;

    # Static frontend
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # API reverse proxy
    location /api/ {
        proxy_pass http://127.0.0.1:${PORT}/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
    }
}
NGINX

  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sf "${NCONF}" /etc/nginx/sites-enabled/m365-monitor.conf
  else
    # Distros ohne sites-enabled: in nginx.conf inkludieren Hinweis ausgeben
    echo "Hinweis: Bitte ${NCONF} in Ihre nginx.conf inkludieren (z. B. include /etc/nginx/sites-available/*.conf;)"
  fi

  nginx -t
  systemctl reload nginx
  echo "==> Nginx konfiguriert. Rufe http://${DOMAIN:-<Server-IP>}/ im Browser auf."
  echo "     Für HTTPS ein Zertifikat via certbot einrichten (Let's Encrypt)."
fi

echo ""
echo "================= Deployment abgeschlossen ================="
echo "App-Verzeichnis : ${APP_DIR}"
echo "Service         : m365-monitor (systemd)"
echo "API             : http://127.0.0.1:${PORT}/api (lokal, via Nginx publiziert wenn aktiviert)"
if [[ "${WITH_NGINX}" -eq 1 ]]; then
  echo "Frontend        : http://${DOMAIN:-<Server-IP>}/"
else
  echo "Frontend        : Sie können das Frontend auch z. B. über jeden Webserver ausliefern."
  echo "                 (root: ${APP_DIR}/frontend)"
fi
echo "============================================================"
