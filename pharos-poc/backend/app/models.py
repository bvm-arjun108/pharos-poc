from typing import List, Literal

from pydantic import BaseModel, Field

Grade = Literal["LOW", "MEDIUM", "HIGH"]
Recommendation = Literal["APPROVE", "DENY", "ESCALATE"]
Severity = Literal["low", "medium", "high"]


# ---- Case (from Snowflake / mock) ----
class Party(BaseModel):
    name: str
    country: str
    id_type: str


class GsiHit(BaseModel):
    list: str
    matched_name: str
    match_score: float
    matched_fields: List[str]


class History(BaseModel):
    transfers_30d: int
    total_30d_usd: float
    avg_amount_usd: float


class CaseRecord(BaseModel):
    mtcn: str
    sender: Party
    receiver: Party
    amount: float
    currency: str
    corridor: str
    channel: str
    gsi_hit: GsiHit
    history: History
    flags: List[str] = Field(default_factory=list)


# ---- Agent outputs ----
class RiskIndicator(BaseModel):
    indicator: str
    severity: Severity
    evidence: str


class DataAnalysis(BaseModel):
    grade: Grade
    recommendation: Recommendation
    confidence: float
    risk_indicators: List[RiskIndicator]
    rationale: str


class DocumentFinding(BaseModel):
    finding: str
    severity: Severity
    evidence: str


class DocumentAnalysis(BaseModel):
    detected_language: str
    document_summary: str
    document_findings: List[DocumentFinding]
    grade: Grade
    recommendation: Recommendation
    confidence: float
    grade_changed: bool
    change_reason: str
    rationale: str
