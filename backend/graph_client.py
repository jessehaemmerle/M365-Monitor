import os, time
from typing import Dict, Any, List
import httpx
from msal import ConfidentialClientApplication

GRAPH_ROOT_V1 = "https://graph.microsoft.com/v1.0"

class GraphClient:
    def __init__(self, tenant_id: str, client_id: str, client_secret: str):
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.client_secret = client_secret
        self.authority = f"https://login.microsoftonline.com/{tenant_id}"
        self.scope = ["https://graph.microsoft.com/.default"]
        self._app = ConfidentialClientApplication(
            client_id=self.client_id,
            client_credential=self.client_secret,
            authority=self.authority,
        )
        self._token: Dict[str, Any] | None = None

    def _get_token(self) -> str:
        if self._token and "expires_at" in self._token and self._token["expires_at"] - time.time() > 60:
            return self._token["access_token"]
        result = self._app.acquire_token_silent(scopes=self.scope, account=None)
        if not result:
            result = self._app.acquire_token_for_client(scopes=self.scope)
        if "access_token" not in result:
            raise RuntimeError(f"Token acquisition failed: {result}")
        # msal returns expires_in seconds; compute absolute expiry
        result["expires_at"] = time.time() + int(result.get("expires_in", 3599))
        self._token = result
        return result["access_token"]

    async def _get(self, url: str, params: Dict[str, Any] | None = None) -> Dict[str, Any]:
        token = self._get_token()
        headers = {"Authorization": f"Bearer {token}"}
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.get(url, headers=headers, params=params)
            r.raise_for_status()
            return r.json()

    # --- Graph wrappers ---
    async def get_health_overviews(self) -> List[Dict[str, Any]]:
        data = await self._get(f"{GRAPH_ROOT_V1}/admin/serviceAnnouncement/healthOverviews")
        return data.get("value", [])

    async def get_health_issues(self) -> List[Dict[str, Any]]:
        data = await self._get(f"{GRAPH_ROOT_V1}/admin/serviceAnnouncement/issues", params={"$top": 50})
        return data.get("value", [])

    async def get_subscribed_skus(self) -> List[Dict[str, Any]]:
        data = await self._get(f"{GRAPH_ROOT_V1}/subscribedSkus")
        return data.get("value", [])

    async def get_tenant(self) -> Dict[str, Any]:
        org = await self._get(f"{GRAPH_ROOT_V1}/organization")
        items = org.get("value", [])
        return items[0] if items else {}

    async def get_signins(self, since_iso: str, top: int = 200) -> List[Dict[str, Any]]:
        # v1.0 is available; pagination omitted for simplicity (top capped)
        params = {
            "$filter": f"createdDateTime ge {since_iso}",
            "$orderby": "createdDateTime asc",
            "$top": str(top),
        }
        data = await self._get(f"{GRAPH_ROOT_V1}/auditLogs/signIns", params=params)
        return data.get("value", [])
