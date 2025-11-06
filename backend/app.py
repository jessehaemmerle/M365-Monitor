import os
from datetime import datetime, timedelta, timezone
from typing import List
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv

from graph_client import GraphClient
from models import (
    HealthIssue, HealthOverview, HealthResponse,
    LicenseSku, LicenseResponse,
    SignInBucket, SignInSummary,
    TenantInfo, TenantResponse
)

load_dotenv()
TENANT_ID = os.getenv("TENANT_ID", "")
CLIENT_ID = os.getenv("CLIENT_ID", "")
CLIENT_SECRET = os.getenv("CLIENT_SECRET", "")
ALLOWED_ORIGINS = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",")]

app = FastAPI(title="M365‑Monitor API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS if ALLOWED_ORIGINS != ["*"] else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

graph = GraphClient(TENANT_ID, CLIENT_ID, CLIENT_SECRET)

@app.get("/api/ping")
def ping():
    return {"ok": True, "time": datetime.now(timezone.utc).isoformat()}

@app.get("/api/health", response_model=HealthResponse)
async def health():
    over = await graph.get_health_overviews()
    issues = await graph.get_health_issues()

    services: List[HealthOverview] = []
    for s in over:
        services.append(HealthOverview(service=s.get("service", "unknown"), status=s.get("status", "unknown")))

    open_issues: List[HealthIssue] = []
    for i in issues:
        open_issues.append(HealthIssue(
            id=i.get("id", ""),
            service=i.get("service", None),
            title=i.get("title", None),
            impactDescription=i.get("impactDescription", None),
            classification=i.get("classification", None),
            status=i.get("status", None),
            startDateTime=i.get("startDateTime", None),
            lastModifiedDateTime=i.get("lastModifiedDateTime", None),
        ))

    # nur offene/vor kurzem geänderte Issues oben halten
    open_issues = [x for x in open_issues if (x.status or "").lower() != "servicerestored"]

    return HealthResponse(services=services, openIssues=open_issues)

@app.get("/api/licenses", response_model=LicenseResponse)
async def licenses():
    skus_raw = await graph.get_subscribed_skus()
    skus: List[LicenseSku] = []
    for s in skus_raw:
        enabled = s.get("prepaidUnits", {}).get("enabled", 0)
        consumed = int(s.get("consumedUnits", 0))
        warning = None
        if enabled > 0 and consumed / max(enabled, 1) >= 0.9:
            warning = "≥90% genutzt"
        skus.append(LicenseSku(
            skuId=s.get("skuId", ""),
            skuPartNumber=s.get("skuPartNumber", ""),
            consumedUnits=consumed,
            enabled=enabled,
            warning=warning,
        ))
    return LicenseResponse(skus=skus)

@app.get("/api/tenant", response_model=TenantResponse)
async def tenant():
    t = await graph.get_tenant()
    domains = [d.get("name") for d in t.get("verifiedDomains", []) if d.get("name")]
    return TenantResponse(tenant=TenantInfo(
        id=t.get("id", ""),
        displayName=t.get("displayName", None),
        verifiedDomains=domains,
    ))

@app.get("/api/signins", response_model=SignInSummary)
async def signins(hours: int = 24):
    hours = max(1, min(hours, 168))  # 1..168h
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    # Graph filter requires Zulu ISO format
    since_iso = since.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    data = await graph.get_signins(since_iso)

    # Bucketize per hour
    buckets = {}
    total = 0
    failed = 0
    for item in data:
        ts = item.get("createdDateTime")
        status = item.get("status", {})
        error_code = int(status.get("errorCode", 0)) if status else 0
        key = ts[:13] + ":00:00Z" if ts else "unknown"
        if key not in buckets:
            buckets[key] = {"total": 0, "failed": 0}
        buckets[key]["total"] += 1
        total += 1
        if error_code != 0:
            buckets[key]["failed"] += 1
            failed += 1

    # ensure all hours present
    ordered = []
    cur = since.replace(minute=0, second=0, microsecond=0)
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    while cur <= end:
        key = cur.isoformat().replace("+00:00", "Z")
        v = buckets.get(key, {"total": 0, "failed": 0})
        ordered.append(SignInBucket(timestamp=key, total=v["total"], failed=v["failed"]))
        cur += timedelta(hours=1)

    failure_rate = (failed / total) * 100 if total else 0.0

    return SignInSummary(
        windowHours=hours,
        total=total,
        failed=failed,
        failureRate=round(failure_rate, 2),
        buckets=ordered,
    )

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run("app:app", host="0.0.0.0", port=port, reload=True)
