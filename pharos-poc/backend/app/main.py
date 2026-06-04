import logging
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from . import agents
from .config import settings
from .repositories import get_repository

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("pharos")

app = FastAPI(title="Pharos POC API", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

repo = get_repository()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "agents": "mock" if settings.USE_MOCK_AGENTS else "bedrock",
        "model": settings.BEDROCK_MODEL_ID,
        "region": settings.AWS_REGION,
        "snowflake": settings.SNOWFLAKE_MODE,
    }


@app.post("/api/cases/{mtcn}/analyze")
def analyze(mtcn: str):
    """Phase 1: fetch the case, run the data-analysis agent, return case + grade."""
    try:
        case = repo.get_case(mtcn)
    except Exception as e:  # noqa: BLE001
        logger.exception("case fetch failed")
        raise HTTPException(status_code=502, detail=f"Case fetch failed: {e}")

    try:
        analysis = agents.analyze_case_data(case)
    except Exception as e:  # noqa: BLE001
        logger.exception("data analysis failed")
        raise HTTPException(
            status_code=503,
            detail=(
                f"Analysis failed: {e}. Check AWS credentials and Bedrock model access, "
                "or set USE_MOCK_AGENTS=true to run without AWS."
            ),
        )

    return {"case": case, "analysis": analysis}


@app.post("/api/cases/{mtcn}/documents")
async def analyze_documents(
    mtcn: str,
    file: UploadFile = File(...),
    prior_grade: Optional[str] = Form(None),
):
    """Phase 2: re-run analysis with an uploaded document, return the updated grade."""
    try:
        case = repo.get_case(mtcn)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Case fetch failed: {e}")

    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")

    try:
        analysis = agents.analyze_document(
            case, data, file.filename or "document", file.content_type or "", prior_grade
        )
    except Exception as e:  # noqa: BLE001
        logger.exception("document analysis failed")
        raise HTTPException(
            status_code=503,
            detail=(
                f"Document analysis failed: {e}. Check AWS credentials and Bedrock model "
                "access, or set USE_MOCK_AGENTS=true."
            ),
        )

    return {"analysis": analysis}


@app.post("/api/cases/{mtcn}/decision")
def decision(mtcn: str, action: str = Form(...), grade: Optional[str] = Form(None)):
    """Record the analyst's approve/deny. POC: logged, not persisted."""
    if action not in ("APPROVED", "DENIED"):
        raise HTTPException(status_code=400, detail="action must be APPROVED or DENIED")
    logger.info("DECISION mtcn=%s action=%s grade=%s", mtcn, action, grade)
    return {"mtcn": mtcn, "action": action, "grade": grade, "recorded": True}
