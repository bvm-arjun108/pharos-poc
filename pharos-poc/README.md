# Pharos POC — agentic case grading

A runnable POC of the two-phase compliance flow:

1. Enter an **MTCN**, click **Analyze** → backend fetches the case and a **data-analysis agent** grades the transaction data.
2. On the results page, **upload a document** → a **document-analysis agent** translates it (if needed), re-grades, and updates the analysis.
3. A human analyst **approves or denies** the case.

**Stack:** React (Vite) frontend · FastAPI backend · agents on the **Strands SDK** calling **Amazon Bedrock** · Snowflake (pluggable; mock by default).

```
pharos-poc/
├── backend/        FastAPI + Strands agents
│   └── app/
│       ├── main.py          routes: /analyze, /documents, /decision, /health
│       ├── agents.py        the two Strands+Bedrock agents (+ mock fallback)
│       ├── repositories.py  mock + Snowflake case data
│       ├── models.py        Pydantic contracts
│       └── config.py        env settings
└── frontend/       Vite + React + Tailwind UI
    └── src/{App.jsx, api.js, ...}
```

## Prerequisites

- Python 3.10+
- Node 18+
- (Optional, for real grading) AWS credentials with Bedrock access — see below.

## 1. Backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate              # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --reload --port 8000
```

(Or just `./run.sh`, which does all of the above.)

Backend is now on http://localhost:8000 — check http://localhost:8000/health.

### Run modes (set in `backend/.env`)

| Goal | Settings |
|---|---|
| Run the whole stack with **no AWS, no Snowflake** | `USE_MOCK_AGENTS=true`, `SNOWFLAKE_MODE=mock` |
| Real **Strands + Bedrock** grading, mock case data | `USE_MOCK_AGENTS=false`, `SNOWFLAKE_MODE=mock` |
| Real grading **and** real Snowflake | `USE_MOCK_AGENTS=false`, `SNOWFLAKE_MODE=real` + Snowflake creds |

Start with mock mode to confirm the flow works, then turn on Bedrock.

## 2. Frontend

In a second terminal:

```bash
cd frontend
npm install
cp .env.example .env        # VITE_API_URL=http://localhost:8000
npm run dev
```

Open http://localhost:5173.

## 3. Test it

1. Click a sample MTCN chip (`8042196375` is high-risk, `5113380027` is low-risk) or type any MTCN, then **Analyze**.
2. You land on the results page with a grade and risk indicators.
3. Upload a document (PDF, image, or text — try one in another language) and click **Analyze document**. The grade and analysis update, and the detected language is shown.
4. Click **Approve** or **Deny**.

## Enabling Bedrock (real grading)

1. Configure AWS credentials any standard way (`aws configure`, env vars, or an SSO profile). boto3 picks them up automatically.
2. In the **Bedrock console → Model access**, enable the Claude model you intend to use, in the same region as `AWS_REGION`.
3. Set `BEDROCK_MODEL_ID` in `backend/.env` to a model/inference-profile you have access to (default: `us.anthropic.claude-3-5-sonnet-20241022-v2:0`).
4. Set `USE_MOCK_AGENTS=false` and restart the backend.

> If `BedrockModel(...)` raises on a keyword like `max_tokens` or `temperature`, your installed `strands-agents` version maps inference params differently — remove that kwarg in `backend/app/agents.py` → `get_model()`.

## Enabling Snowflake (real case data)

1. Set `SNOWFLAKE_MODE=real` and fill the `SNOWFLAKE_*` values in `backend/.env`.
2. Edit `SnowflakeCaseRepository.get_case()` in `backend/app/repositories.py` — the SQL and the row→`CaseRecord` mapping are a template; adapt the table and column names to your Pharos schema. Keep the query parameterized.

## What's real vs simplified

- **Real:** the agentic grading (Strands agents on Bedrock), document translation/analysis, the two-phase flow, the approve/deny gate.
- **Simplified for the POC:** synchronous request/response (no SSE streaming yet — you see a spinner per phase), client-side orchestration of the two calls, and no persistence/audit trail. Those are the next increments.

## Troubleshooting

- **CORS error in the browser:** make sure `CORS_ORIGINS` in `backend/.env` includes the frontend origin (`http://localhost:5173`).
- **503 from /analyze:** AWS creds or Bedrock model access are missing — fix access, or set `USE_MOCK_AGENTS=true`.
- **`ModuleNotFoundError: strands`:** `pip install -r requirements.txt` inside the activated venv.
- **Frontend can't reach backend:** confirm the backend is on :8000 and `VITE_API_URL` matches.
