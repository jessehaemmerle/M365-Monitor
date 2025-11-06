# M365‑Monitor
Leichtes Dashboard für Microsoft 365 (Service Health, Lizenzen, Sign‑In‑Trends) – ohne npm, ohne Docker.

## Voraussetzungen
- Python 3.10+
- Entra ID App Registration (Client Credentials, Application Permissions)
- Admin Consent für die o.g. Berechtigungen

## Installation
```bash
python -m venv .venv
. .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r backend/requirements.txt
cp backend/.env.example backend/.env
# .env mit TENANT_ID, CLIENT_ID, CLIENT_SECRET befüllen
python backend/app.py
```
Backend läuft unter http://localhost:8000.  
Das Frontend kannst du z. B. lokal mit einem simplen Static Server ausliefern (oder auf deinen bestehenden Webserver kopieren):
```bash
# Beispiel: Python simple server
cd frontend
python -m http.server 5500
```
Öffne http://localhost:5500 – das Dashboard ruft automatisch das Backend unter :8000 auf.

## Konfiguration in Entra ID
1. Entra ID → **App registrations** → **New registration**
   - Name: `M365‑Monitor`
   - Supported account types: *Accounts in this organizational directory only*
2. **Certificates & secrets** → **New client secret** → Wert sichern.
3. **API permissions** → **Microsoft Graph** → **Application permissions**:
   - `ServiceHealth.Read.All`
   - `AuditLog.Read.All`
   - `Directory.Read.All`
   - Optional: `Reports.Read.All`
   → **Grant admin consent**
4. **Overview**: `Application (client) ID`, `Directory (tenant) ID` notieren.

## Deployment‑Hinweise
- **Produktiv-Host**: Backend hinter Reverse Proxy (Nginx/IIS) mit HTTPS. `ALLOWED_ORIGINS` in `.env` setzen.
- **Secrets**: Client Secret sicher verwalten (z. B. Umgebungsvariablen, Key Vault).
- **Skalierung**: uvicorn mit mehreren Workern (z. B. `--workers 2`).

## Erweiterungen (Roadmap)
- Alerts (E‑Mail/Teams Webhook) bei Health‑Statuswechsel oder hoher Sign‑In‑Fehlerquote
- Paginierung & Aggregation für Sign‑Ins >200 Events
- Nutzungsreports (Graph Reports API) für EXO/SharePoint/Teams
- Exchange Online Mailflow‑Fehler (über Reports API)
- Persistenz (SQLite/Postgres) für historische Trends
- Multi‑Tenant-Unterstützung (mehrere App Registrations/Tenants)

---
**Schnellstart (TL;DR)**  
1) App in Entra anlegen → Rechte geben → Admin consent.  
2) `.env` füllen → Backend starten → Frontend öffnen.  
3) Fertig – Dashboard zeigt Health, Lizenzen und Sign‑Ins.
