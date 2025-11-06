from pydantic import BaseModel
from typing import List, Optional

class HealthIssue(BaseModel):
    id: str
    service: Optional[str] = None
    title: Optional[str] = None
    impactDescription: Optional[str] = None
    classification: Optional[str] = None  # incident, advisory
    status: Optional[str] = None          # serviceOperational, serviceRestored, etc.
    startDateTime: Optional[str] = None
    lastModifiedDateTime: Optional[str] = None

class HealthOverview(BaseModel):
    service: str
    status: str

class HealthResponse(BaseModel):
    services: List[HealthOverview]
    openIssues: List[HealthIssue]

class LicenseSku(BaseModel):
    skuId: str
    skuPartNumber: str
    consumedUnits: int
    enabled: int
    warning: Optional[str] = None

class LicenseResponse(BaseModel):
    skus: List[LicenseSku]

class SignInBucket(BaseModel):
    timestamp: str
    total: int
    failed: int

class SignInSummary(BaseModel):
    windowHours: int
    total: int
    failed: int
    failureRate: float
    buckets: List[SignInBucket]

class TenantInfo(BaseModel):
    id: str
    displayName: Optional[str] = None
    verifiedDomains: List[str] = []

class TenantResponse(BaseModel):
    tenant: TenantInfo
