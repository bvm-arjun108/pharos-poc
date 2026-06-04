"""Data-analysis and document-analysis agents on Strands SDK + Amazon Bedrock.

The orchestration (run data agent, then document agent) lives in main.py. Each
function here is one agent producing one typed result. Strands API surface used:

    from strands import Agent
    from strands.models import BedrockModel
    agent = Agent(model=..., system_prompt=...)
    result = agent(prompt_or_content_blocks)   # str(result) -> the text response

If your installed strands-agents version rejects a BedrockModel kwarg (e.g.
max_tokens), remove it in `get_model()` — these map to inference params and vary
slightly across versions.
"""
import json
import logging
import re
from typing import Optional, Type, TypeVar

from pydantic import BaseModel

from .config import settings
from .models import (
    CaseRecord,
    DataAnalysis,
    DocumentAnalysis,
    DocumentFinding,
    RiskIndicator,
)

logger = logging.getLogger("pharos.agents")
T = TypeVar("T", bound=BaseModel)

DATA_SYSTEM = (
    "You are the data-analysis agent in 'Pharos', a sanctions/AML case-grading system "
    "for a global money-transfer compliance team. You are given the transaction/case "
    "data for a transfer that triggered a screening (GSI) hit. Analyze ONLY this data "
    "(no supporting documents yet) and assign a risk grade. "
    "Respond with ONLY minified JSON, no markdown, no prose outside the JSON. Schema: "
    '{"grade":"LOW|MEDIUM|HIGH","recommendation":"APPROVE|DENY|ESCALATE",'
    '"confidence":0-1,"risk_indicators":[{"indicator":string,'
    '"severity":"low|medium|high","evidence":string}],"rationale":string}. '
    "Use 3-5 indicators max and a 2-3 sentence rationale."
)

DOC_SYSTEM = (
    "You are the document-analysis + grading agent in 'Pharos'. A supporting document "
    "has been uploaded for a case already graded on transaction data alone. If the "
    "document is NOT in English, translate it to English as part of your analysis and "
    "report the detected language. Re-grade the case considering BOTH the transaction "
    "data and the document. "
    "Respond with ONLY minified JSON, no markdown. Schema: "
    '{"detected_language":string,"document_summary":string,'
    '"document_findings":[{"finding":string,"severity":"low|medium|high",'
    '"evidence":string}],"grade":"LOW|MEDIUM|HIGH",'
    '"recommendation":"APPROVE|DENY|ESCALATE","confidence":0-1,'
    '"grade_changed":boolean,"change_reason":string,"rationale":string}. Be concise.'
)

_model = None


def get_model():
    global _model
    if _model is None:
        from strands.models import BedrockModel

        kwargs = dict(
            model_id=settings.BEDROCK_MODEL_ID,
            region_name=settings.AWS_REGION,
            temperature=0.2,
            max_tokens=2000,
        )
        if settings.BEDROCK_GUARDRAIL_ID:
            kwargs["guardrail_id"] = settings.BEDROCK_GUARDRAIL_ID
            kwargs["guardrail_version"] = settings.BEDROCK_GUARDRAIL_VERSION
        _model = BedrockModel(**kwargs)
    return _model


def _extract_json(text: str) -> dict:
    t = text.strip()
    t = re.sub(r"^```(?:json)?", "", t).strip()
    t = re.sub(r"```$", "", t).strip()
    start, end = t.find("{"), t.rfind("}")
    if start == -1 or end == -1:
        raise ValueError("model did not return a JSON object")
    return json.loads(t[start : end + 1])


def _run(system_prompt: str, content, output_model: Type[T]) -> T:
    """Create a fresh Strands agent, run it, parse + validate the JSON response."""
    from strands import Agent

    agent = Agent(model=get_model(), system_prompt=system_prompt)
    result = agent(content)  # content may be a str or a list of content blocks
    text = str(result)
    if not text.strip():
        raise ValueError("empty response from model")
    return output_model.model_validate(_extract_json(text))


def _doc_content_block(data: bytes, filename: str, content_type: str):
    """Build a Bedrock content block from the uploaded file (pdf / image / text)."""
    ct = (content_type or "").lower()
    lower = filename.lower()
    safe_name = re.sub(r"[^a-zA-Z0-9 \-\(\)\[\]]", "-", filename.rsplit(".", 1)[0])[:60] or "document"

    if ct == "application/pdf" or lower.endswith(".pdf"):
        return {"document": {"format": "pdf", "name": safe_name, "source": {"bytes": data}}}

    if ct.startswith("image/") or lower.endswith((".png", ".jpg", ".jpeg", ".gif", ".webp")):
        if lower.endswith((".jpg", ".jpeg")):
            fmt = "jpeg"
        elif lower.endswith(".png"):
            fmt = "png"
        elif lower.endswith(".gif"):
            fmt = "gif"
        elif lower.endswith(".webp"):
            fmt = "webp"
        else:
            fmt = ct.split("/")[-1] if "/" in ct else "png"
            fmt = fmt if fmt in ("png", "jpeg", "gif", "webp") else "png"
        return {"image": {"format": fmt, "source": {"bytes": data}}}

    text = data.decode("utf-8", errors="replace")[:20000]
    return {"text": f"Document filename: {filename}\n\nContent:\n{text}"}


# --------------------------------------------------------------------------- #
# Public API used by the orchestrator (main.py)
# --------------------------------------------------------------------------- #
def analyze_case_data(case: CaseRecord) -> DataAnalysis:
    if settings.USE_MOCK_AGENTS:
        return _mock_data(case)
    content = f"Case data for MTCN {case.mtcn}:\n{case.model_dump_json(indent=2)}"
    return _run(DATA_SYSTEM, content, DataAnalysis)


def analyze_document(
    case: CaseRecord,
    file_bytes: bytes,
    filename: str,
    content_type: str,
    prior_grade: Optional[str] = None,
) -> DocumentAnalysis:
    if settings.USE_MOCK_AGENTS:
        return _mock_doc(prior_grade)
    instruction = (
        f"Transaction case data:\n{case.model_dump_json()}\n\n"
        + (f"Prior data-only grade: {prior_grade}\n\n" if prior_grade else "")
        + "Now analyze the attached supporting document and re-grade the case."
    )
    content = [{"text": instruction}, _doc_content_block(file_bytes, filename, content_type)]
    return _run(DOC_SYSTEM, content, DocumentAnalysis)


# --------------------------------------------------------------------------- #
# Mock fallbacks (USE_MOCK_AGENTS=true) so the full stack runs without AWS
# --------------------------------------------------------------------------- #
def _mock_data(case: CaseRecord) -> DataAnalysis:
    s = case.gsi_hit.match_score
    structuring = any(re.search(r"threshold|structur", f, re.I) for f in case.flags)
    clean = any(re.search(r"consistent|long-standing|legitimate", f, re.I) for f in case.flags)
    if s >= 0.75 or structuring:
        grade, rec = "HIGH", "ESCALATE"
    elif clean and not structuring and s < 0.7:
        grade, rec = "LOW", "APPROVE"
    elif s >= 0.5:
        grade, rec = "MEDIUM", "ESCALATE"
    else:
        grade, rec = "LOW", "APPROVE"
    indicators = [
        RiskIndicator(
            indicator="Screening match strength",
            severity="high" if s >= 0.75 else "medium" if s >= 0.5 else "low",
            evidence=f"{case.gsi_hit.list} (score {s})",
        )
    ]
    if structuring:
        indicators.append(
            RiskIndicator(
                indicator="Possible structuring",
                severity="high",
                evidence=next(f for f in case.flags if re.search(r"threshold|structur", f, re.I)),
            )
        )
    return DataAnalysis(
        grade=grade, recommendation=rec, confidence=0.6, risk_indicators=indicators,
        rationale="Mock grade (USE_MOCK_AGENTS=true): rule-based over the case fields, no Bedrock call.",
    )


def _mock_doc(prior_grade: Optional[str]) -> DocumentAnalysis:
    grade = prior_grade if prior_grade in ("LOW", "MEDIUM", "HIGH") else "MEDIUM"
    return DocumentAnalysis(
        detected_language="English (mock)",
        document_summary="Mock document analysis — set USE_MOCK_AGENTS=false to use Bedrock.",
        document_findings=[],
        grade=grade, recommendation="ESCALATE", confidence=0.6,
        grade_changed=False, change_reason="No change in mock mode.",
        rationale="Mock re-grade; document not actually analyzed in mock mode.",
    )
