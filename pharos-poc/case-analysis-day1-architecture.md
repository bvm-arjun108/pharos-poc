# Case Analysis Platform — Day 1 Production Architecture & Implementation Guide

**Status:** Approved design (v1.0 — Day 1 scope)
**Pattern:** Async job processing with polling (create → poll → fetch)
**Stack:** Angular (frontend) · API Gateway (HTTP API) · FastAPI on ECS Fargate · Redis (job queue) · PostgreSQL (system of record) · AWS Bedrock · Okta (OIDC)
**Callers:** AWS-hosted UI (in-VPC) and on-prem UI (Direct Connect / VPN)
**Data classification:** Protected data — private networking, encryption at every hop

---

## 1. Executive Summary

The platform runs multi-agent case analysis (data retrieval → data analysis → document analysis) against AWS Bedrock. Analyses take 1–2 minutes. Rather than holding connections open, the system uses the **async job pattern**: every API call completes in milliseconds, work happens in a background worker, and the UI polls for progress.

**Why not streaming / SSE pub/sub (the "Flux question"):** Spring WebFlux-style reactive SSE has a full Python equivalent (asyncio + sse-starlette + Redis pub/sub), so language was not the constraint. The deciding factors were: (a) API Gateway is the mandated front door and its 29-second integration timeout is incompatible with long-lived connections; (b) the product shape is "submit → receive analysis," where stage-level progress delivers the UX value; (c) Day 1 simplicity is an explicit requirement. The architecture keeps a clean seam for adding push delivery (SSE/WebSocket) in Phase 2 — workers already publish stage transitions; only the delivery edge would be added. On the client, Angular's RxJS provides the same reactive-streams programming model as Flux, applied to a polling observable.

**Day 1 topology — deliberately minimal:**

```
Angular UI (AWS + on-prem)
   │  Authorization: Bearer <Okta JWT>
   ▼
API Gateway (HTTP API) ── Okta JWT authorizer at the edge
   │  VPC Link (private)
   ▼
Internal ALB
   ▼
ECS Fargate — ONE service, two processes:
   ├── FastAPI (API process)        — answers all HTTP calls in <100 ms
   └── arq worker (worker process)  — runs the 3-agent pipeline → Bedrock
        │ job tickets                      │ status + results
        ▼                                  ▼
      Redis (queue) ────────────────► PostgreSQL (system of record)
```

**Roles:**

| Component | Day 1 job |
|---|---|
| API Gateway | Front door: Okta JWT validation, throttling, private VPC Link |
| FastAPI | Three endpoints; writes case rows; enqueues jobs; reads status/results |
| Redis | **Job queue only** (crash-safe handoff, retries, dead-letter). Not a cache on Day 1. |
| PostgreSQL | Everything persistent: case records, status, stage outputs, final summary |
| Worker (arq) | Claims jobs, runs agents sequentially, persists each stage, guarded status updates |

**Deliberately postponed to Phase 2:** Redis status cache, separate worker service, progressive partial results in the UI, push delivery (SSE/WebSocket). Section 11 covers the evolution path; Section 10 covers the confirmed Day 1.5 hardening items. Nothing in Day 1 must be rewritten to get there.

---

## 2. API Contract

Base URL: `https://api.cases.internal.example.com/v1`
All endpoints require `Authorization: Bearer <JWT>` (Okta, audience `api://case-analysis`, scope `cases.invoke`). The gateway authorizer rejects bad tokens before they reach the service; the service re-validates and enforces ownership (defense in depth).

**Common error envelope** (all non-2xx responses):

```json
{
  "error": {
    "code": "CASE_NOT_FOUND",
    "message": "Case 7f3e... does not exist",
    "details": {}
  }
}
```

### 2.1 `POST /v1/cases` — createCase

Creates a case and starts processing. Returns immediately.

**Request headers:**

| Header | Required | Purpose |
|---|---|---|
| `Authorization` | yes | Bearer JWT |
| `Idempotency-Key` | recommended | Client-generated UUID; duplicate submits return the original case instead of creating a second one |
| `Content-Type` | yes | `application/json` |

**Request body:**

```json
{
  "input": {
    "document_refs": ["s3://bucket/contracts/abc.pdf"],
    "query": "Summarize obligations and flag unusual clauses"
  },
  "options": { "priority": "normal" }
}
```

**Responses:**

`201 Created` — new case:

```json
{
  "case_id": "7f3e9a12-...-c4",
  "status": "queued",
  "created_at": "2026-06-11T14:03:21Z",
  "links": {
    "status": "/v1/cases/7f3e9a12-...-c4/status",
    "summary": "/v1/cases/7f3e9a12-...-c4/summary"
  }
}
```

`200 OK` — idempotency replay (same `Idempotency-Key` seen before): returns the **existing** case in the same shape.
`429 Too Many Requests` — two causes, distinguishable by body: gateway throttling (no body / gateway shape) or the **per-user concurrency cap** (`error.code: "CONCURRENCY_LIMIT"`, §10.3) when the user already has the max number of active cases. Clients should surface "you have analyses still running" rather than auto-retrying.
`400` invalid body · `401` invalid/missing token.

### 2.2 `GET /v1/cases/{case_id}/status` — caseStatus

Lightweight progress read. The UI polls this every ~3 seconds.

**Response `200 OK`:**

```json
{
  "case_id": "7f3e9a12-...-c4",
  "status": "analyzing",
  "stage": {
    "current": "analysis",
    "completed": ["retrieval"],
    "sequence": ["retrieval", "analysis", "doc_analysis"]
  },
  "updated_at": "2026-06-11T14:03:52Z"
}
```

`status` values: `queued | retrieving | analyzing | doc_analysis | complete | error`.

On `error`, two extra fields appear:

```json
{ "status": "error", "failed_stage": "analysis", "error_reason": "UPSTREAM_MODEL_ERROR" }
```

`403` — case exists but belongs to another user (token `sub` ≠ case owner).
`404` — unknown case.

**Polling contract for clients:** poll every 3 s (±500 ms jitter); stop on `complete` or `error`; treat >10 min without a terminal status as stuck and surface a support path.

### 2.3 `GET /v1/cases/{case_id}/summary` — caseSummary

Fetches the full result. Call once after status reaches `complete`.

**Response `200 OK`** (status = complete):

```json
{
  "case_id": "7f3e9a12-...-c4",
  "status": "complete",
  "completed_at": "2026-06-11T14:05:40Z",
  "summary": {
    "retrieval":    { "documents_found": 4, "sources": ["..."] },
    "analysis":     { "key_findings": ["..."], "narrative": "..." },
    "doc_analysis": { "flagged_clauses": ["..."], "assessment": "..." }
  }
}
```

`409 Conflict` — case not finished yet; body includes current status so a racing client can resume polling:

```json
{ "error": { "code": "CASE_NOT_READY", "message": "Case is still processing", "details": { "status": "analyzing" } } }
```

If status = `error`, returns `200` with `"status": "error"`, `failed_stage`, `error_reason`, and any stage outputs that **did** complete (partial value beats nothing).
### 2.4 `GET /v1/cases` — listCases

Returns the caller's own cases, newest first, for a "my analyses" history screen. Always scoped to the token's `sub` — there is no way to list other users' cases.

**Query parameters:** `limit` (default 20, max 50) · `cursor` (opaque, from previous response).

**Response `200 OK`:**

```json
{
  "items": [
    { "case_id": "7f3e...", "status": "complete", "created_at": "2026-06-11T14:03:21Z" },
    { "case_id": "9a1b...", "status": "analyzing", "created_at": "2026-06-11T13:58:02Z" }
  ],
  "next_cursor": "MjAyNi0wNi0xMVQxMzo1ODowMlo_OWExYg"
}
```

`next_cursor` is null when there are no more pages. Implementation is keyset pagination on `(created_at, case_id)` — see §10.4.

---

## 3. Database Schema (PostgreSQL)

```sql
CREATE TABLE cases (
    case_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_sub        TEXT        NOT NULL,
    status           TEXT        NOT NULL DEFAULT 'queued',
    failed_stage     TEXT,
    error_reason     TEXT,
    idempotency_key  TEXT UNIQUE,
    claimed_by       TEXT,
    claimed_at       TIMESTAMPTZ,
    input            JSONB       NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_cases_owner   ON cases (owner_sub, created_at DESC);
CREATE INDEX idx_cases_status  ON cases (status) WHERE status NOT IN ('complete','error');

CREATE TABLE stage_results (
    case_id      UUID        NOT NULL REFERENCES cases(case_id),
    stage        TEXT        NOT NULL,
    output       JSONB       NOT NULL,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (case_id, stage)          -- idempotency backstop: a stage can exist once
);
```

Design notes: `JSONB` for agent outputs (schema evolves freely, queryable later); the partial index keeps "find active cases" fast as history grows; the `(case_id, stage)` primary key is the **race-condition backstop** (Section 5.4); `idempotency_key UNIQUE` is the duplicate-submit guard.

---

## 4. Concurrency & Race-Condition Handling

PostgreSQL MVCC already guarantees that **polling reads never block worker writes and never see half-written rows** — read/write contention requires zero code. Three specific races remain; each is closed with one guarded statement. No `SELECT FOR UPDATE`, no advisory locks needed at this scale.

### 4.1 Double job delivery → atomic claim

Redis may redeliver a job if a worker stalls. Two workers must never process the same case. The worker's **first** action is a compare-and-set; only one winner is possible:

```sql
UPDATE cases
SET status = 'retrieving', claimed_by = :worker_id, claimed_at = now(), updated_at = now()
WHERE case_id = :case_id AND status = 'queued'
RETURNING case_id;
```

Zero rows returned → another worker owns it → drop the job silently.

### 4.2 Retried job re-runs finished stages → idempotent stages

A worker crash after stage 2 persisted but before completion triggers redelivery. Each stage checks before running, so resume costs only the interrupted stage (and never double-bills Bedrock):

```python
if await stage_exists(case_id, stage_name):
    continue                       # already done — skip
output = await run_agent(...)      # the expensive part
await insert_stage_result(case_id, stage_name, output)   # PK (case_id, stage) backstops
```

### 4.3 Stale status overwrite → guarded transitions

Statuses form a one-way state machine. Every status write names its legal predecessor, so a zombie writer's stale update silently does nothing:

```sql
UPDATE cases SET status = 'analyzing', updated_at = now()
WHERE case_id = :case_id AND status = 'retrieving';
```

### 4.4 Double-click on submit → idempotency key

`POST /cases` inserts with the client's `Idempotency-Key`; on unique-violation, fetch and return the existing case with `200`. Two rapid clicks produce one case.

---

## 5. Backend Implementation (FastAPI + arq)

### 5.1 Project structure

```
app/
├── main.py        # FastAPI app, lifespan (pg pool, redis pool)
├── auth.py        # Okta JWT validation dependency
├── routes.py      # the three endpoints
├── worker.py      # arq worker: claim → stages → guarded updates
├── agents.py      # the three agent implementations (Bedrock calls)
├── db.py          # asyncpg queries (claim, transitions, stage upserts)
└── config.py      # pydantic-settings
requirements.txt   # fastapi, uvicorn, asyncpg, arq, PyJWT[crypto], aioboto3, pydantic-settings
Dockerfile
```

### 5.2 Okta JWT validation (`auth.py`)

```python
import jwt
from jwt import PyJWKClient
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from app.config import settings

_jwks = PyJWKClient(f"{settings.okta_issuer}/v1/keys", cache_keys=True)
_bearer = HTTPBearer(auto_error=True)

def validate_token(creds: HTTPAuthorizationCredentials = Depends(_bearer)) -> dict:
    try:
        key = _jwks.get_signing_key_from_jwt(creds.credentials)
        claims = jwt.decode(
            creds.credentials, key.key, algorithms=["RS256"],
            audience=settings.okta_audience, issuer=settings.okta_issuer,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token") from exc
    scopes = claims.get("scp") or claims.get("scope", "").split()
    if settings.required_scope not in scopes:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient scope")
    return claims
```

(The gateway authorizer already filtered bad tokens; this in-app check is defense in depth and supplies `sub` for ownership.)

### 5.3 Routes (`routes.py`)

```python
import uuid
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from app.auth import validate_token
from app import db

router = APIRouter(prefix="/v1")

@router.post("/cases", status_code=201)
async def create_case(request: Request, body: dict,
                      claims: dict = Depends(validate_token),
                      idempotency_key: str | None = Header(default=None)):
    pool, queue = request.app.state.pg, request.app.state.arq
    if idempotency_key:
        existing = await db.find_by_idem_key(pool, idempotency_key, claims["sub"])
        if existing:
            return existing                                   # 200-equivalent replay
    case = await db.insert_case(pool, owner_sub=claims["sub"],
                                input=body, idempotency_key=idempotency_key)
    await queue.enqueue_job("process_case", str(case["case_id"]))
    return case

@router.get("/cases/{case_id}/status")
async def case_status(case_id: uuid.UUID, request: Request,
                      claims: dict = Depends(validate_token)):
    case = await db.get_case(request.app.state.pg, case_id)
    _authorize(case, claims)
    return db.to_status_view(case)

@router.get("/cases/{case_id}/summary")
async def case_summary(case_id: uuid.UUID, request: Request,
                       claims: dict = Depends(validate_token)):
    pool = request.app.state.pg
    case = await db.get_case(pool, case_id)
    _authorize(case, claims)
    if case["status"] not in ("complete", "error"):
        raise HTTPException(409, detail={"code": "CASE_NOT_READY",
                                         "details": {"status": case["status"]}})
    stages = await db.get_stage_results(pool, case_id)
    return db.to_summary_view(case, stages)

def _authorize(case, claims):
    if case is None:
        raise HTTPException(404, detail={"code": "CASE_NOT_FOUND"})
    if case["owner_sub"] != claims["sub"]:
        raise HTTPException(403, detail={"code": "FORBIDDEN"})
```

### 5.4 Worker (`worker.py`)

```python
from arq import cron
from app import db, agents
from app.config import settings

STAGES = [
    ("retrieving",   "retrieval",    agents.run_retrieval),
    ("analyzing",    "analysis",     agents.run_analysis),
    ("doc_analysis", "doc_analysis", agents.run_doc_analysis),
]

async def process_case(ctx, case_id: str):
    pool, worker_id = ctx["pg"], ctx["worker_id"]

    claimed = await db.claim_case(pool, case_id, worker_id)     # §4.1 atomic claim
    if not claimed and not await db.is_resumable(pool, case_id, worker_id):
        return                                                  # duplicate delivery — drop

    prior = "queued"
    try:
        for status, stage, run in STAGES:
            await db.transition(pool, case_id, frm=prior, to=status)   # §4.3 guarded
            if not await db.stage_exists(pool, case_id, stage):        # §4.2 idempotent
                output = await run(pool, case_id)                      # Bedrock inside
                await db.insert_stage_result(pool, case_id, stage, output)
            prior = status
        await db.transition(pool, case_id, frm=prior, to="complete")
    except Exception as exc:
        await db.mark_error(pool, case_id, failed_stage=prior, reason=type(exc).__name__)
        raise   # let arq count the retry

class WorkerSettings:
    functions = [process_case]
    max_tries = 3                      # bounded retries with backoff
    job_timeout = 600
    redis_settings = settings.arq_redis
```

Agent calls (`agents.py`) wrap Bedrock with bounded retry + jittered backoff on throttling only; payload content is **never logged** — case IDs, stages, durations, statuses only.

### 5.5 Process model & Dockerfile

One Fargate task runs both processes (split into separate services in Phase 2 without code changes):

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt . 
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY start.sh .
EXPOSE 8080
CMD ["./start.sh"]   # starts: uvicorn app.main:app & arq app.worker.WorkerSettings
```

`start.sh` launches Uvicorn and the arq worker, and exits if either dies (so ECS replaces the task — never run half-alive).

---

## 6. Frontend Implementation (Angular & React)

The API is frontend-agnostic by design: HTTPS + JSON + Bearer token + the polling contract in §2. Any client framework implements the same flow. §6.1–6.3 show the Angular implementation; §6.4 shows the React equivalent. Both teams build strictly against the §2 contract.

### 6.1 Auth — Okta

Use `@okta/okta-angular` + `@okta/okta-auth-js` (Authorization Code + PKCE for user-facing SPA; the on-prem service caller uses client-credentials server-side instead). Register an HTTP interceptor that attaches the access token:

```typescript
@Injectable()
export class AuthInterceptor implements HttpInterceptor {
  constructor(private oktaAuth: OktaAuth) {}
  intercept(req: HttpRequest<unknown>, next: HttpHandler) {
    const token = this.oktaAuth.getAccessToken();
    return next.handle(token
      ? req.clone({ setHeaders: { Authorization: `Bearer ${token}` } })
      : req);
  }
}
```

### 6.2 Case service — the RxJS polling stream

This is where Angular gives you the Flux-style reactive model on the client. The poll is a declarative observable pipeline: emit every 3 s → fetch status → complete the stream when terminal.

```typescript
export type CaseStatus = {
  case_id: string;
  status: 'queued'|'retrieving'|'analyzing'|'doc_analysis'|'complete'|'error';
  stage: { current: string; completed: string[]; sequence: string[] };
  failed_stage?: string;
  error_reason?: string;
};

@Injectable({ providedIn: 'root' })
export class CaseService {
  private base = environment.apiBase;                 // https://api.../v1
  constructor(private http: HttpClient) {}

  createCase(input: unknown): Observable<{ case_id: string }> {
    return this.http.post<{ case_id: string }>(`${this.base}/cases`, { input }, {
      headers: { 'Idempotency-Key': crypto.randomUUID() },   // double-click guard
    });
  }

  pollStatus(caseId: string): Observable<CaseStatus> {
    const TERMINAL = ['complete', 'error'];
    return timer(0, 3000).pipe(
      switchMap(() => this.http.get<CaseStatus>(`${this.base}/cases/${caseId}/status`)),
      retry({ count: 3, delay: (_, n) => timer(1000 * 2 ** n) }),  // transient blips
      takeWhile(s => !TERMINAL.includes(s.status), true),          // emit terminal, then complete
      timeout({ first: 600_000 })                                  // 10-min stuck guard
    );
  }

  getSummary(caseId: string): Observable<CaseSummary> {
    return this.http.get<CaseSummary>(`${this.base}/cases/${caseId}/summary`);
  }
}
```

### 6.3 Component flow & UI states

```typescript
submit(input: unknown) {
  this.view = 'submitting';
  this.caseSvc.createCase(input).pipe(
    tap(({ case_id }) => { this.caseId = case_id; this.view = 'processing'; }),
    switchMap(({ case_id }) => this.caseSvc.pollStatus(case_id)),
    tap(s => this.progress = s),                       // drives the stepper
    filter(s => s.status === 'complete' || s.status === 'error'),
    switchMap(s => s.status === 'complete'
      ? this.caseSvc.getSummary(this.caseId)
      : of({ error: s })),
  ).subscribe({
    next: r => { this.result = r; this.view = 'done'; },
    error: () => { this.view = 'failed'; },            // network/timeout path
  });
}
```

**UI state machine (what the user sees):**

| State | Trigger | Render |
|---|---|---|
| `idle` | initial | Submit form |
| `submitting` | POST in flight | Disabled button, spinner (sub-second) |
| `processing` | 201 received | **3-step stepper**: Retrieving → Analyzing → Reviewing documents; current step animated, completed steps checked. Driven directly by `stage.completed` / `stage.current`. |
| `done` | summary fetched | Render report sections from `summary.retrieval / analysis / doc_analysis` |
| `failed` (case error) | `status: error` | "Analysis failed at *{failed_stage}*" + **Retry** button (calls `createCase` again — new idempotency key) |
| `failed` (network/stuck) | retry/timeout exhausted | "Connection lost — your case is still processing" + **Resume** button (restarts `pollStatus(caseId)` — the backend never depended on the browser staying alive) |

Two UX details worth keeping: persist `caseId` to `sessionStorage` on creation so a page refresh resumes polling instead of losing the case; and unsubscribe on component destroy (`takeUntilDestroyed()`) so abandoned screens stop polling.

### 6.4 React integration (same contract, React idiom)

**Auth:** `@okta/okta-react` (Auth Code + PKCE) with its own Okta app integration / client ID — same issuer and audience as the Angular app, so the backend sees identical tokens. Attach the token with an axios interceptor:

```typescript
api.interceptors.request.use(async (config) => {
  const token = oktaAuth.getAccessToken();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});
```

**Polling with TanStack Query** (the React-idiomatic equivalent of the RxJS pipeline — `refetchInterval` replaces `timer + switchMap`, returning `false` replaces `takeWhile`):

```tsx
const TERMINAL = ['complete', 'error'];

function useCaseStatus(caseId?: string) {
  return useQuery({
    queryKey: ['caseStatus', caseId],
    queryFn: () => api.get<CaseStatus>(`/cases/${caseId}/status`).then(r => r.data),
    enabled: !!caseId,
    refetchInterval: (query) =>
      TERMINAL.includes(query.state.data?.status ?? '') ? false : 3000,
    retry: 3,
    retryDelay: (n) => 1000 * 2 ** n,
  });
}

function useCaseSummary(caseId?: string, status?: string) {
  return useQuery({
    queryKey: ['caseSummary', caseId],
    queryFn: () => api.get<CaseSummary>(`/cases/${caseId}/summary`).then(r => r.data),
    enabled: !!caseId && status === 'complete',   // fires exactly once, when ready
  });
}
```

**Component flow:**

```tsx
function CaseAnalysis() {
  const [caseId, setCaseId] = useState<string>();
  const create = useMutation({
    mutationFn: (input: unknown) =>
      api.post('/cases', { input },
        { headers: { 'Idempotency-Key': crypto.randomUUID() } }).then(r => r.data),
    onSuccess: ({ case_id }) => {
      setCaseId(case_id);
      sessionStorage.setItem('caseId', case_id);   // refresh-resume, same as Angular
    },
  });
  const { data: status } = useCaseStatus(caseId);
  const { data: summary } = useCaseSummary(caseId, status?.status);

  // Render the same six UI states as §6.3 from `create`, `status`, `summary`
}
```

The §6.3 UI state table applies unchanged — it is defined by the API contract, not the framework. TanStack Query gives the refresh-resume, request dedup, and stop-on-unmount behaviors largely for free.

---

## 7. AWS Infrastructure — Step by Step

1. **VPC & networking** — private subnets across 3 AZs; VPC endpoints (PrivateLink) for `bedrock-runtime`, ECR (api + dkr), CloudWatch Logs, Secrets Manager; no public subnets needed.
2. **PostgreSQL** — Aurora PostgreSQL (or RDS) **Multi-AZ**, KMS-encrypted, TLS enforced (`rds.force_ssl=1`). Put **RDS Proxy** in front: Fargate tasks churn connections and Postgres punishes that. SG: 5432 from Fargate SG only.
3. **Redis (ElastiCache)** — single shard, **Multi-AZ auto-failover**, TLS + AUTH (token in Secrets Manager), KMS at rest. Used as arq's broker. SG: 6379 from Fargate SG only.
4. **ECS Fargate** — one service, min 2 tasks across AZs; 1 vCPU / 2 GB to start; task role scoped to: `bedrock:InvokeModel*` on your model ARNs, Secrets Manager read for DB/Redis creds, nothing else. Autoscale on CPU + request count.
5. **Internal ALB** — HTTPS (ACM), health check `/health`, default timeouts are fine (no long-lived connections anymore — note how much config anxiety the polling pattern deleted).
6. **API Gateway (HTTP API)** —
   - **JWT authorizer**: issuer = your Okta authorization server URI, audience = `api://case-analysis`. Bad tokens die at the edge.
   - **VPC Link** → internal ALB (keeps the backend private).
   - Routes: `POST /v1/cases`, `GET /v1/cases/{id}/status`, `GET /v1/cases/{id}/summary`.
   - **Throttling**: e.g., 50 rps burst / 20 rps steady per stage; protects Postgres from a polling stampede.
   - CORS: allow the exact UI origins (Angular app, React app(s), on-prem UI), `Authorization` + `Idempotency-Key` headers, `GET, POST`.
7. **On-prem reachability** — Direct Connect (or VPN) as established; on-prem callers reach the API Gateway endpoint per your gateway type (regional endpoint over private path, or private API + interface endpoint if org policy requires no public DNS). Verify firewall allows HTTPS to the gateway.
8. **Okta** — authorization server with scope `cases.invoke`; **one SPA app integration per frontend** (Angular and React get separate client IDs — independent token policy and revocation) plus a service app (client credentials) for the on-prem caller; all share the same issuer and audience `api://case-analysis`, so the backend is identical for every client.
9. **Secrets & config** — DB creds, Redis AUTH token in Secrets Manager (KMS CMK); injected into tasks as secrets, never env-baked into images.

---

## 8. Failure Modes & Expected Behavior

| Failure | What happens | User impact |
|---|---|---|
| Fargate task dies mid-analysis | Unacked job redelivered by Redis; new worker claims (§4.1), skips finished stages (§4.2), resumes | "Analyzing" lasts a bit longer; nothing lost |
| Duplicate job delivery | Atomic claim — loser drops the job | None; Bedrock billed once |
| Agent fails after retries | `status: error` + `failed_stage` persisted | Clear stage-level error + Retry button |
| User closes browser mid-run | Worker finishes anyway; result persisted | Reopen later → status `complete` → summary loads |
| Network blip during polling | RxJS retry with backoff; case unaffected server-side | Invisible, or "Resume" after exhaustion |
| Double-click submit | Idempotency key returns existing case | One case, one charge |
| Redis failover | Few seconds of queue unavailability; enqueues retry; in-flight jobs unaffected (state in Postgres) | None |
| Aurora failover | Seconds of write errors; arq retries the job; API returns 503 briefly | Rare transient error |
| Stale/zombie worker writes | Guarded transitions no-op illegal writes (§4.3) | None |

---

## 9. Security & Observability Summary

**Security:** Okta JWT verified twice (gateway edge + in-app); per-case ownership check (`sub` vs `owner_sub`); private networking end-to-end (VPC Link, internal ALB, PrivateLink for AWS APIs); TLS on every hop (client→GW→ALB→app, app→Postgres, app→Redis); KMS CMKs at rest (Aurora, ElastiCache, Logs, Secrets); least-privilege task role; **no payload or model output in logs**; audit log of every case creation and read with `sub`, case ID, source IP → SIEM.

**Observability:** `case_id` as correlation key across API, queue, worker, and DB writes; metrics — cases created/completed/failed per stage, stage durations, queue depth, Bedrock first-call latency, poll request rate; alarms — queue depth growth, `started but no terminal status in 10 min` (silent-failure detector), error-rate per stage, Aurora/Redis failovers; dashboard per concern (traffic, pipeline health, infra).

---

## 10. Day 1.5 Hardening — Implementation Guide

Six confirmed improvements. None adds new infrastructure; each hardens what exists. They are independent — implement in any order, in parallel across teams.

### 10.1 Stuck-case janitor (backend) — *highest priority*

**Gap closed:** a job that dies in a way nothing detects (retries exhausted, poisoned task, worker wedged) leaves a case in a non-terminal status forever — and a user polling forever. The janitor guarantees every case reaches a terminal state.

Steps:

1. Add a cron function to `worker.py` — arq has scheduling built in, no new component:

```python
import logging
from arq import cron

log = logging.getLogger("janitor")
STUCK_AFTER = "15 minutes"

async def reap_stuck_cases(ctx):
    rows = await ctx["pg"].fetch(f"""
        UPDATE cases
        SET status = 'error',
            failed_stage = status,
            error_reason = 'TIMEOUT',
            updated_at = now()
        WHERE status NOT IN ('complete', 'error')
          AND (
                claimed_at < now() - interval '{STUCK_AFTER}'            -- claimed, then died
             OR (claimed_at IS NULL
                 AND created_at < now() - interval '{STUCK_AFTER}')      -- queued, never picked up
          )
        RETURNING case_id
    """)
    for r in rows:
        log.warning("janitor reaped case_id=%s", r["case_id"])
    return len(rows)

class WorkerSettings:
    functions = [process_case]
    cron_jobs = [cron(reap_stuck_cases, minute=set(range(0, 60, 5)))]   # every 5 min
    max_tries = 3
    job_timeout = 600
```

2. The guarded-transition rule (§4.3) protects against the rare race where a slow-but-alive worker finishes *after* being reaped: its final `complete` transition names `doc_analysis` as predecessor, the row now says `error`, the write no-ops. Reap wins, deterministically.
3. **Alarm on it:** emit the reaped count as a CloudWatch metric; any nonzero value is a bug to investigate — the janitor is a safety net, not a workflow.
4. Tune `STUCK_AFTER` to ~3× your worst legitimate case duration (15 min assumes ≤5-min analyses).

### 10.2 OpenAPI contract + generated clients (backend publishes, frontends consume)

**Gap closed:** the §2 contract is enforced by compilers instead of by discipline, across three teams.

Steps:

1. Backend: FastAPI already serves the spec at `/openapi.json`. Pin metadata in `main.py` (`title`, `version`) and add response models (Pydantic) to the three routes so the spec is precise, not `object`.
2. CI exports and commits the spec on every backend merge:

```bash
python -c "import json; from app.main import app; print(json.dumps(app.openapi()))" > openapi.json
```

3. Add a CI diff gate: if `openapi.json` changed, the PR requires a frontend-team review label. Contract changes become visible events, never surprises.
4. Both frontends generate types from the committed spec:

```bash
npx openapi-typescript openapi.json -o src/api/schema.d.ts
```

   Angular uses the types with `HttpClient`; React pairs them with `openapi-fetch` or axios. Regenerate in each frontend's CI so a contract drift fails the build — that is the entire point.

### 10.3 Per-user concurrency cap (backend)

**Gap closed:** a runaway client retry loop (or abuse) creating unbounded cases — i.e., unbounded **Bedrock spend**. This guards the only expensive line item in the system.

Steps:

1. In `create_case`, before insert:

```python
MAX_ACTIVE_CASES = 5   # config, not constant

active = await pool.fetchval(
    "SELECT count(*) FROM cases WHERE owner_sub = $1 AND status NOT IN ('complete','error')",
    claims["sub"])
if active >= MAX_ACTIVE_CASES:
    raise HTTPException(429, detail={
        "code": "CONCURRENCY_LIMIT",
        "message": f"You have {active} analyses in progress. Wait for one to finish.",
    })
```

2. The partial index from §3 (`idx_cases_status`) makes this count cheap.
3. Known and accepted: two simultaneous creates can both pass the check (check-then-insert race). The cap is a guardrail against runaways, not a strict invariant — off-by-one is harmless, and fixing it properly (serializable txn or advisory lock) isn't worth the cost. Document this so nobody "fixes" it later.
4. Frontend handling: on `CONCURRENCY_LIMIT`, show "You have analyses still running" with a link to the history screen (§10.4) — never auto-retry.

### 10.4 `GET /v1/cases` list endpoint (backend + UI screen)

**Gap closed:** "where's the analysis I ran this morning?" — turns one-shot tool into product with history.

Steps:

1. Route (keyset pagination — stable under inserts, no OFFSET scans):

```python
import base64

@router.get("/cases")
async def list_cases(request: Request, claims: dict = Depends(validate_token),
                     limit: int = 20, cursor: str | None = None):
    limit = min(limit, 50)
    pool = request.app.state.pg
    if cursor:
        created_at, case_id = _decode_cursor(cursor)     # base64 "iso8601_uuid"
        rows = await pool.fetch("""
            SELECT case_id, status, created_at FROM cases
            WHERE owner_sub = $1 AND (created_at, case_id) < ($2, $3)
            ORDER BY created_at DESC, case_id DESC LIMIT $4""",
            claims["sub"], created_at, case_id, limit)
    else:
        rows = await pool.fetch("""
            SELECT case_id, status, created_at FROM cases
            WHERE owner_sub = $1
            ORDER BY created_at DESC, case_id DESC LIMIT $2""",
            claims["sub"], limit)
    next_cursor = _encode_cursor(rows[-1]) if len(rows) == limit else None
    return {"items": [dict(r) for r in rows], "next_cursor": next_cursor}
```

2. The `idx_cases_owner (owner_sub, created_at DESC)` index from §3 already serves this — no schema change.
3. UI: a simple "My analyses" list; rows with non-terminal status link back into the polling view (the `caseId`-resume path from §6.3 already handles this), completed rows open the summary.

### 10.5 Decaying poll interval (frontend only)

**Gap closed:** long-running cases hammering the status endpoint; roughly halves polling load at scale. The backend never knows.

Policy: 3 s for the first ~20 polls (one minute), then 7 s until terminal.

Angular (`pollStatus` revised — `repeat` with a computed delay replaces the fixed `timer`):

```typescript
pollStatus(caseId: string): Observable<CaseStatus> {
  const TERMINAL = ['complete', 'error'];
  let polls = 0;
  return defer(() =>
    this.http.get<CaseStatus>(`${this.base}/cases/${caseId}/status`)
  ).pipe(
    repeat({ delay: () => timer(++polls <= 20 ? 3000 : 7000) }),
    retry({ count: 3, delay: (_, n) => timer(1000 * 2 ** n) }),
    takeWhile(s => !TERMINAL.includes(s.status), true),
    timeout({ each: 60_000, first: 600_000 })
  );
}
```

React (`useCaseStatus` revised — `refetchInterval` already receives the query object):

```tsx
refetchInterval: (query) => {
  if (TERMINAL.includes(query.state.data?.status ?? '')) return false;
  return query.state.dataUpdateCount <= 20 ? 3000 : 7000;
},
```

Keep the ±500 ms jitter from the §2 polling contract on top of either.

### 10.6 Alembic migrations (backend discipline)

**Gap closed:** the first post-launch schema change being a hand-run `ALTER` on production.

Steps:

1. `pip install alembic` → `alembic init migrations`; point `sqlalchemy.url` at an env var in `env.py` (same secret the app uses).
2. Create the **initial migration** containing the §3 `CREATE TABLE`s exactly — from day one, an empty database is fully buildable by `alembic upgrade head`.
3. Wire into deploy: run `alembic upgrade head` as a pipeline step (one-off ECS task or pre-deploy job) **before** the new task definition rolls out. Migrations must be backward-compatible with the still-running old version (expand → migrate → contract pattern for anything destructive).
4. Team rule, enforced in review: **any PR touching the schema contains its migration.** No exceptions; that's the entire value.

---

## 11. Phase 2 Evolution Path (designed-in seams)

1. **Progressive results** — caseStatus already knows completed stages; extend it (or the UI) to fetch finished stage outputs early so the report assembles section-by-section during the run. Backend change: ~one endpoint/queryparam.
2. **Redis status cache** — when poll volume shows up in DB metrics: workers mirror status to Redis, status reads go Redis-first. No contract change.
3. **Worker split** — move the arq process to its own Fargate service; scale on queue depth. No code change, one deploy pipeline.
4. **Push delivery (the pub/sub upgrade)** — workers publish stage/token events; add an SSE edge (ALB path) or API Gateway **WebSocket API** for delivery. Angular swaps the polling observable for an event observable — components barely change since both are Observables.
5. **Token streaming** — if word-by-word output becomes a product requirement, reintroduce the Redis Streams resumable-SSE design (documented separately in the streaming architecture guide).

---

## 12. Go-Live Checklist

**Backend**
- [ ] Atomic claim, idempotent stages, guarded transitions implemented exactly as §4
- [ ] Idempotency-Key handling on POST (unique index + replay returns existing)
- [ ] arq: max_tries=3, job_timeout set, dead-letter handling decided
- [ ] No payload/model output in logs; structured logs carry case_id + sub
- [ ] `/health` endpoint (no DB/Bedrock dependency)

**Frontend**
- [ ] Interceptor attaches Okta token; refresh handled before expiry
- [ ] Polling: 3 s + jitter, backoff retry, terminal-stop, 10-min stuck guard
- [ ] caseId persisted to sessionStorage; refresh resumes polling
- [ ] All six UI states implemented, incl. stage-level error + Retry, and Resume after network loss
- [ ] Polling unsubscribed on component destroy

**AWS**
- [ ] Gateway JWT authorizer (issuer/audience verified), throttling, CORS for exactly two origins
- [ ] VPC Link → internal ALB; nothing public
- [ ] RDS Proxy in place; Aurora Multi-AZ; `rds.force_ssl`
- [ ] ElastiCache Multi-AZ, TLS, AUTH; SGs locked to Fargate
- [ ] PrivateLink endpoints for Bedrock/ECR/Logs/Secrets
- [ ] Task role least-privilege; secrets via Secrets Manager

**Day 1.5 hardening (§10)**
- [ ] Janitor cron live; reaped-count metric + alarm (nonzero = investigate); reap verified by wedging a test case
- [ ] `openapi.json` committed; CI diff gate; both frontends generate types in CI and fail on drift
- [ ] Concurrency cap returns 429 `CONCURRENCY_LIMIT` at the configured max; frontends show the running-analyses message, never auto-retry
- [ ] `GET /v1/cases` keyset pagination verified across page boundaries; history screen links resume polling for active cases
- [ ] Poll decay verified: 3 s → 7 s after one minute, jitter retained, both frontends
- [ ] `alembic upgrade head` runs in the deploy pipeline before task rollout; empty DB builds from migrations alone

**Validation before launch**
- [ ] Kill the Fargate task mid-analysis → case resumes, finishes, single Bedrock charge
- [ ] Submit double-click → exactly one case created
- [ ] Force a stage failure → UI shows failed stage + Retry works
- [ ] Close browser mid-run, return after completion → summary loads
- [ ] Wrong-user token on someone else's case → 403
- [ ] Load test the polling path at expected peak (status endpoint p99 < 50 ms)
