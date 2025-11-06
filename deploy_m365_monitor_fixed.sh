#!/usr/bin/env bash
# M365-Monitor deploy script (fixed & robust)
# - Creates venv at /opt/m365-monitor/.venv
# - Sets up systemd
# - Optional Nginx (uses sites-enabled if present; otherwise conf.d)
set -euo pipefail

# -------- Defaults --------
APP_DIR="/opt/m365-monitor"      # lowercase; NO spaces
RUN_USER="${SUDO_USER:-$(whoami)}"
PORT="8000"
SRC_DIR=""
ENV_FILE="/etc/m365-monitor.env"
WITH_NGINX=0
DOMAIN=""

usage() {
  cat <<'USAGE'
Usage: sudo ./deploy_m365_monitor.sh [options]

  --src PATH            Project root (contains backend/ and frontend/)
  --app-dir PATH        Install dir (default: /opt/m365-monitor)
  --user USER           Service user (default: $SUDO_USER or current user)
  --port PORT           Uvicorn port (default: 8000; binds 127.0.0.1)
  --env-file PATH       Env file path (default: /etc/m365-monitor.env)
  --with-nginx          Configure Nginx (static frontend + /api proxy)
  --domain NAME         Nginx server_name (e.g., monitor.example.com)
  -h, --help            Show this help
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
  echo "Please run as root (use sudo)."; exit 1
fi

# Auto-detect SRC if not provided
if [[ -z "${SRC_DIR}" ]]; then
  if [[ -d "backend" && -d "frontend" ]]; then SRC_DIR="$(pwd)"
  else echo "Error: --src not provided and no backend/frontend in current dir."; exit 1
  fi
fi

# Validate project structure
[[ -f "${SRC_DIR}/backend/app.py" ]] || { echo "Error: ${SRC_DIR}/backend/app.py not found."; exit 1; }
[[ -f "${SRC_DIR}/backend/requirements.txt" ]] || { echo "Error: ${SRC_DIR}/backend/requirements.txt not found."; exit 1; }
[[ -f "${SRC_DIR}/frontend/index.html" ]] || { echo "Error: ${SRC_DIR}/frontend/index.html not found."; exit 1; }

echo "==> Installing to ${APP_DIR} (user: ${RUN_USER}, port: ${PORT})"

# -------- Package helpers --------
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
fi

ensure_pkg() {
  local pkg="$1"
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" ;;
    dnf) dnf install -y -q "$pkg" ;;
    yum) yum install -y -q "$pkg" ;;
    *) echo "!! Install manually: $pkg" ;;
  esac
}

need_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then echo "==> Installing: $pkg"; ensure_pkg "$pkg" || true; fi
}

# -------- Ensure system deps --------
need_cmd python3 python3
python3 -c "import venv" 2>/dev/null || { echo "==> Installing python3-venv"; ensure_pkg python3-venv || true; }
need_cmd pip3 python3-pip
RSYNC_AVAILABLE=0; command -v rsync >/dev/null 2>&1 && RSYNC_AVAILABLE=1

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
id -u "${RUN_USER}" >/dev/null 2>&1 && chown -R "${RUN_USER}:${RUN_USER}" "${APP_DIR}"

# -------- Python venv & deps --------
if [[ ! -d "${APP_DIR}/.venv" ]]; then
  echo "==> Creating venv at ${APP_DIR}/.venv"
  sudo -u "${RUN_USER}" python3 -m venv "${APP_DIR}/.venv"
fi
[[ -x "${APP_DIR}/.venv/bin/python" ]] || { echo "ERROR: venv creation failed. Install python3-venv and re-run."; exit 1; }

echo "==> Installing Python requirements"
sudo -u "${RUN_USER}" bash -lc "source '${APP_DIR}/.venv/bin/activate' && pip install --upgrade pip && pip install -r '${APP_DIR}/backend/requirements.txt'"

# -------- Env file --------
if [[ "${ENV_FILE}" == "/etc/m365-monitor.env" && ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${SRC_DIR}/backend/.env" ]]; then cp "${SRC_DIR}/backend/.env" "${ENV_FILE}"
  elif [[ -f "${SRC_DIR}/backend/.env.example" ]]; then cp "${SRC_DIR}/backend/.env.example" "${ENV_FILE}"
  else touch "${ENV_FILE}"
  fi
fi

# Ensure PORT and ALLOWED_ORIGINS
grep -qE '^PORT=' "${ENV_FILE}" 2>/dev/null && sed -i "s/^PORT=.*/PORT=${PORT}/" "${ENV_FILE}" || echo "PORT=${PORT}" >> "${ENV_FILE}"
if [[ -n "${DOMAIN}" ]]; then ALLOWED="https://${DOMAIN},http://localhost:5500"; else ALLOWED="*"; fi
grep -qE '^ALLOWED_ORIGINS=' "${ENV_FILE}" 2>/dev/null && sed -i "s|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=${ALLOWED}|" "${ENV_FILE}" || echo "ALLOWED_ORIGINS=${ALLOWED}" >> "${ENV_FILE}"
chmod 640 "${ENV_FILE}"; chown root:"${RUN_USER}" "${ENV_FILE}" || true

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
systemctl --no-pager --full status m365-monitor.service || true

# -------- Optional: Nginx --------
if [[ "${WITH_NGINX}" -eq 1 ]]; then
  command -v nginx >/dev/null 2>&1 || { echo "==> Installing Nginx"; ensure_pkg nginx || true; }
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled || true
  TARGET_CONF="/etc/nginx/sites-available/m365-monitor.conf"
  if [[ ! -d /etc/nginx/sites-enabled ]]; then
    # RHEL/Alpine style: use conf.d
    TARGET_CONF="/etc/nginx/conf.d/m365-monitor.conf"
  fi
  cat > "${TARGET_CONF}" <<NGINX
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
    ln -sf "${TARGET_CONF}" /etc/nginx/sites-enabled/m365-monitor.conf
  fi
  nginx -t
  systemctl reload nginx
  echo "==> Nginx ready. Visit: http://${DOMAIN:-<server-ip>}/"
fi

echo "=== Done ==="
echo "Install dir : ${APP_DIR}"
echo "Service     : m365-monitor (systemd)"
echo "API         : http://127.0.0.1:${PORT}/api"
