#!/usr/bin/env bash
# M365-Monitor deploy script (robust version)
# - installs python deps
# - creates venv at /opt/m365-monitor/.venv
# - sets up systemd service
# - optional Nginx reverse proxy + static hosting
set -euo pipefail

# -------- Defaults --------
APP_DIR="/opt/m365-m onitor"        # lowercase by design
RUN_USER="${SUDO_USER:-$(whoami)}"
PORT="8000"
SRC_DIR=""
ENV_FILE="/etc/m365-monitor.env"
WITH_NGINX=0
DOMAIN=""

# -------- Usage --------
usage() {
  cat <<'USAGE'
Usage: sudo ./deploy_m365_monitor.sh [options]

  --src PATH            Path to project root (contains backend/ and frontend/)
  --app-dir PATH        Install dir (default: /opt/m365-monitor)
  --user USER           Linux user to run the service (default: $SUDO_USER or current user)
  --port PORT           Uvicorn port (default: 8000; bound to 127.0.0.1)
  --env-file PATH       Path to env file (default: /etc/m365-monitor.env)
  --with-nginx          Configure Nginx (static frontend + /api proxy)
  --domain NAME         Domain for Nginx (e.g., monitor.example.com)
  -h, --help            Show this help

Examples:
  sudo ./deploy_m365_monitor.sh --src ./M365-Monitor
  sudo ./deploy_m365_monitor.sh --src ./M365-Monitor --with-nginx --domain monitor.example.com
USAGE
}

# -------- Parse args --------
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
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

# Auto-detect SRC if not provided
if [[ -z "${SRC_DIR}" ]]; then
  if [[ -d "backend" && -d "frontend" ]]; then
    SRC_DIR="$(pwd)"
  else
    echo "Error: --src not provided and no backend/frontend in current dir."
    exit 1
  fi
fi

# Validate project structure
if [[ ! -f "${SRC_DIR}/backend/app.py" ]]; then
  echo "Error: ${SRC_DIR}/backend/app.py not found."
  exit 1
fi
if [[ ! -f "${SRC_DIR}/backend/requirements.txt" ]]; then
  echo "Error: ${SRC_DIR}/backend/requirements.txt not found."
  exit 1
fi
if [[ ! -f "${SRC_DIR}/frontend/index.html" ]]; then
  echo "Error: ${SRC_DIR}/frontend/index.html not found."
  exit 1
fi

echo "==> Installing to ${APP_DIR} (service user: ${RUN_USER}, port: ${PORT})"

# -------- Package helpers --------
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
fi

ensure_pkg() {
  local pkg="$1"
  if [[ "$PKG_MGR" == "apt" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
  elif [[ "$PKG_MGR" == "dnf" ]]; then
    dnf install -y -q "$pkg"
  elif [[ "$PKG_MGR" == "yum" ]]; then
    yum install -y -q "$pkg"
  else
    echo "!! Package manager not detected; please install manually: $pkg"
  fi
}

need_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "==> Installing missing dependency: $pkg"
    ensure_pkg "$pkg" || true
  fi
}

# -------- Ensure system deps --------
need_cmd python3 python3
if ! python3 -c "import venv" 2>/dev/null; then
  echo "==> Installing python3-venv (or ensure Python venv is available)"
  ensure_pkg python3-venv || true
fi
need_cmd pip3 python3-pip
# rsync is nice-to-have; fallback to cp -a
RSYNC_AVAILABLE=0
if command -v rsync >/dev/null 2>&1; then
  RSYNC_AVAILABLE=1
else
  echo "==> rsync not found; will use cp -a for copying."
fi

# -------- Copy project --------
mkdir -p "${APP_DIR}"
if [[ $RSYNC_AVAILABLE -eq 1 ]]; then
  rsync -a --delete "${SRC_DIR}/backend/" "${APP_DIR}/backend/"
  rsync -a --delete "${SRC_DIR}/frontend/" "${APP_DIR}/frontend/"
else
  rm -rf "${APP_DIR}/backend" "${APP_DIR}/frontend"
  mkdir -p "${APP_DIR}/backend" "${APP_DIR}/frontend"
  cp -a "${SRC_DIR}/backend/." "${APP_DIR}/backend/"
  cp -a "${SRC_DIR}/frontend/." "${APP_DIR}/frontend/"
fi

# Set ownership
if id -u "${RUN_USER}" >/dev/null 2>&1; then
  chown -R "${RUN_USER}:${RUN_USER}" "${APP_DIR}"
fi

# -------- Python venv & deps --------
if [[ ! -d "${APP_DIR}/.venv" ]]; then
  echo "==> Creating virtualenv at ${APP_DIR}/.venv"
  sudo -u "${RUN_USER}" python3 -m venv "${APP_DIR}/.venv"
fi
if [[ ! -x "${APP_DIR}/.venv/bin/python" ]]; then
  echo "ERROR: venv creation failed (missing ${APP_DIR}/.venv/bin/python)."
  echo "Please ensure python3-venv is installed, then re-run this script."
  exit 1
fi
echo "==> Installing Python requirements"
sudo -u "${RUN_USER}" bash -lc "source '${APP_DIR}/.venv/bin/activate' && pip install --upgrade pip && pip install -r '${APP_DIR}/backend/requirements.txt'"

# -------- Env file --------
if [[ "${ENV_FILE}" == "/etc/m365-monitor.env" && ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${SRC_DIR}/backend/.env" ]]; then
    cp "${SRC_DIR}/backend/.env" "${ENV_FILE}"
  elif [[ -f "${SRC_DIR}/backend/.env.example" ]]; then
    cp "${SRC_DIR}/backend/.env.example" "${ENV_FILE}"
  else
    touch "${ENV_FILE}"
  fi
fi

# Ensure PORT and ALLOWED_ORIGINS
if grep -qE '^PORT=' "${ENV_FILE}" 2>/dev/null; then
  sed -i "s/^PORT=.*/PORT=${PORT}/" "${ENV_FILE}"
else
  echo "PORT=${PORT}" >> "${ENV_FILE}"
fi

if [[ -n "${DOMAIN}" ]]; then
  ALLOWED="https://${DOMAIN},http://localhost:5500"
else
  ALLOWED="*"
fi
if grep -qE '^ALLOWED_ORIGINS=' "${ENV_FILE}" 2>/dev/null; then
  sed -i "s|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=${ALLOWED}|" "${ENV_FILE}"
else
  echo "ALLOWED_ORIGINS=${ALLOWED}" >> "${ENV_FILE}"
fi

chmod 640 "${ENV_FILE}"
chown root:"${RUN_USER}" "${ENV_FILE}" || true

# -------- systemd service --------
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

echo "==> Service status (tail):"
systemctl --no-pager --full status m365-monitor.service || true

# -------- Optional: Nginx --------
if [[ "${WITH_NGINX}" -eq 1 ]]; then
  if ! command -v nginx >/dev/null 2>&1; then
    echo "==> Installing Nginx"
    ensure_pkg nginx || true
  fi

  NCONF="/etc/nginx/sites-available/m365-monitor.conf"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled || true

  cat > "${NCONF}" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN:-_};

    root ${APP_DIR}/frontend;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

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
    echo "!! Your Nginx does not use sites-enabled; include ${NCONF} in nginx.conf manually."
  fi

  nginx -t
  systemctl reload nginx
  echo "==> Nginx ready. Visit: http://${DOMAIN:-<server-ip>}/"
  echo "    For HTTPS, run: sudo certbot --nginx -d ${DOMAIN}"
fi

echo ""
echo "================ Deployment complete ================"
echo "Install dir  : ${APP_DIR}"
echo "Venv         : ${APP_DIR}/.venv (activate for manual use)"
echo "Service      : m365-monitor (systemd)"
echo "Local API    : http://127.0.0.1:${PORT}/api"
if [[ "${WITH_NGINX}" -eq 1 ]]; then
  echo "Frontend     : http://${DOMAIN:-<server-ip>}/"
else
  echo "Frontend     : Serve ${APP_DIR}/frontend with any web server or add --with-nginx"
fi
echo "====================================================="
