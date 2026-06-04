import React, { useState, useRef } from "react";
import {
  Search, Upload, FileText, Loader2, CheckCircle2, XCircle, AlertTriangle,
  ShieldCheck, Database, Scale, RotateCcw, Languages, ArrowLeft, Bot,
} from "lucide-react";
import { analyzeCase, analyzeDocument, recordDecision } from "./api";

const SAMPLES = ["8042196375", "5113380027"];

const GRADE = {
  LOW: { chip: "bg-emerald-50 text-emerald-700 ring-emerald-200", dot: "bg-emerald-500", label: "Low risk" },
  MEDIUM: { chip: "bg-amber-50 text-amber-700 ring-amber-200", dot: "bg-amber-500", label: "Medium risk" },
  HIGH: { chip: "bg-red-50 text-red-700 ring-red-200", dot: "bg-red-500", label: "High risk" },
};
const SEV = { low: "bg-slate-100 text-slate-600", medium: "bg-amber-100 text-amber-700", high: "bg-red-100 text-red-700" };

const Label = ({ children }) => (
  <div className="text-xs font-medium uppercase tracking-wider text-slate-400">{children}</div>
);
const KV = ({ k, v, mono }) => (
  <div className="flex items-baseline justify-between gap-4 py-1.5 border-b border-slate-100 last:border-0">
    <span className="text-sm text-slate-500">{k}</span>
    <span className={"text-sm text-slate-800 text-right " + (mono ? "font-mono" : "")}>{v}</span>
  </div>
);
const AgentChip = ({ icon: Icon, name, state }) => {
  const s = state === "done" ? "bg-teal-50 text-teal-700 ring-teal-200"
    : state === "run" ? "bg-slate-100 text-slate-600 ring-slate-200"
    : "bg-slate-50 text-slate-400 ring-slate-200";
  return (
    <div className={"inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 " + s}>
      {state === "run" ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
        : state === "done" ? <CheckCircle2 className="h-3.5 w-3.5" />
        : <Icon className="h-3.5 w-3.5" />}
      {name}
    </div>
  );
};

const Header = () => (
  <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/80 backdrop-blur">
    <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-3">
      <div className="flex items-center gap-2">
        <div className="flex h-7 w-7 items-center justify-center rounded-md bg-teal-600 text-white"><ShieldCheck className="h-4 w-4" /></div>
        <div>
          <div className="text-sm font-semibold tracking-tight text-slate-900">Pharos</div>
          <div className="-mt-0.5 text-[11px] text-slate-400">Compliance case analysis</div>
        </div>
      </div>
      <span className="rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-medium uppercase tracking-wide text-slate-500 ring-1 ring-slate-200">POC</span>
    </div>
  </header>
);

const Footer = () => (
  <footer className="mx-auto max-w-5xl px-6 pb-10 pt-4 text-center text-xs text-slate-400">
    POC — case data comes from the backend (mock Snowflake by default); grading runs through Strands + Bedrock. Nothing is persisted.
  </footer>
);

const Card = ({ title, sub, icon: Icon, children }) => (
  <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="mb-4 flex items-center gap-2">
      <Icon className="h-4 w-4 text-slate-400" />
      <h3 className="text-sm font-semibold text-slate-800">{title}</h3>
      {sub && <span className="text-xs text-slate-400">· {sub}</span>}
    </div>
    {children}
  </div>
);

const Pending = ({ text }) => (
  <div className="flex items-center gap-3 text-sm text-slate-500">
    <Loader2 className="h-4 w-4 animate-spin text-teal-600" /> {text}
  </div>
);

const Analysis = ({ indicators, rationale, emptyLabel = "No risk indicators." }) => (
  <div>
    {indicators?.length ? (
      <ul className="space-y-2">
        {indicators.map((it, i) => (
          <li key={i} className="rounded-lg border border-slate-100 p-3">
            <div className="flex items-start justify-between gap-3">
              <span className="text-sm font-medium text-slate-800">{it.indicator || it.finding}</span>
              <span className={"shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium uppercase " + (SEV[it.severity] || SEV.low)}>{it.severity}</span>
            </div>
            {it.evidence && <p className="mt-1 text-xs text-slate-500">{it.evidence}</p>}
          </li>
        ))}
      </ul>
    ) : (
      <p className="text-sm text-slate-400">{emptyLabel}</p>
    )}
    {rationale && (
      <div className="mt-3 rounded-lg bg-slate-50 p-3 ring-1 ring-slate-100">
        <Label>Rationale</Label>
        <p className="mt-1 text-sm text-slate-600">{rationale}</p>
      </div>
    )}
  </div>
);

export default function App() {
  const [view, setView] = useState("search");
  const [mtcn, setMtcn] = useState("");
  const [caseData, setCaseData] = useState(null);
  const [phase1, setPhase1] = useState(null);
  const [phase2, setPhase2] = useState(null);
  const [loading1, setLoading1] = useState(false);
  const [loading2, setLoading2] = useState(false);
  const [file, setFile] = useState(null);
  const [decision, setDecision] = useState(null);
  const [error, setError] = useState(null);
  const [docError, setDocError] = useState(null);
  const fileRef = useRef(null);

  const grade = phase2?.grade || phase1?.grade;
  const rec = phase2?.recommendation || phase1?.recommendation;
  const conf = phase2?.confidence ?? phase1?.confidence;
  const g = grade ? GRADE[grade] : null;

  const startAnalysis = async () => {
    if (!mtcn.trim()) return;
    setView("results");
    setCaseData(null); setPhase1(null); setPhase2(null); setFile(null);
    setDecision(null); setError(null); setDocError(null);
    setLoading1(true);
    try {
      const { case: c, analysis } = await analyzeCase(mtcn.trim());
      setCaseData(c);
      setPhase1(analysis);
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading1(false);
    }
  };

  const runDocument = async () => {
    if (!file || !caseData || !phase1) return;
    setDocError(null);
    setLoading2(true);
    try {
      const { analysis } = await analyzeDocument(mtcn.trim(), file, phase1.grade);
      setPhase2(analysis);
    } catch (e) {
      setDocError(e.message);
    } finally {
      setLoading2(false);
    }
  };

  const decide = (action) => {
    setDecision({ action, ts: new Date().toLocaleString(), grade });
    recordDecision(mtcn.trim(), action, grade);
  };

  const reset = () => {
    setView("search"); setMtcn(""); setCaseData(null); setPhase1(null);
    setPhase2(null); setFile(null); setDecision(null); setError(null); setDocError(null);
  };

  /* ----------------------------- SEARCH ----------------------------- */
  if (view === "search") {
    return (
      <div className="min-h-screen bg-slate-50 text-slate-900">
        <Header />
        <div className="mx-auto flex max-w-2xl flex-col items-center px-6 pt-24 pb-16 text-center">
          <div className="mb-5 inline-flex items-center gap-2 rounded-full bg-teal-50 px-3 py-1 text-xs font-medium text-teal-700 ring-1 ring-teal-200">
            <ShieldCheck className="h-3.5 w-3.5" /> GSI case grading
          </div>
          <h1 className="text-3xl font-semibold tracking-tight text-slate-900">Analyze a flagged case</h1>
          <p className="mt-3 max-w-md text-slate-500">
            Enter the MTCN of a screened transfer. Pharos pulls the case, grades the transaction data,
            then re-grades once you upload supporting documents.
          </p>

          <div className="mt-8 flex w-full items-center gap-2 rounded-xl border border-slate-200 bg-white p-1.5 shadow-sm focus-within:ring-2 focus-within:ring-slate-900">
            <Search className="ml-2 h-5 w-5 shrink-0 text-slate-400" />
            <input
              value={mtcn}
              onChange={(e) => setMtcn(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && startAnalysis()}
              placeholder="Enter MTCN…"
              className="w-full bg-transparent px-1 py-2 font-mono text-slate-800 outline-none placeholder:font-sans placeholder:text-slate-400"
            />
            <button onClick={startAnalysis} className="shrink-0 rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-slate-800">
              Analyze
            </button>
          </div>

          <div className="mt-5 flex flex-wrap items-center justify-center gap-2">
            <span className="text-xs text-slate-400">Sample cases:</span>
            {SAMPLES.map((k) => (
              <button key={k} onClick={() => setMtcn(k)}
                className="rounded-md border border-slate-200 bg-white px-2.5 py-1 font-mono text-xs text-slate-600 transition hover:border-slate-300 hover:bg-slate-50">
                {k}
              </button>
            ))}
          </div>
        </div>
        <Footer />
      </div>
    );
  }

  /* ----------------------------- RESULTS ---------------------------- */
  return (
    <div className="min-h-screen bg-slate-50 text-slate-900">
      <Header />
      <div className="mx-auto max-w-5xl px-6 py-8">
        <button onClick={reset} className="mb-4 inline-flex items-center gap-1.5 text-sm text-slate-500 transition hover:text-slate-800">
          <ArrowLeft className="h-4 w-4" /> New search
        </button>

        {error && !caseData ? (
          <div className="rounded-xl border border-red-200 bg-red-50 p-6">
            <div className="flex items-center gap-2 font-medium text-red-800">
              <AlertTriangle className="h-5 w-5" /> Could not analyze {mtcn}
            </div>
            <p className="mt-2 text-sm text-red-700">{error}</p>
            <button onClick={startAnalysis} className="mt-4 inline-flex items-center gap-2 rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800">
              <RotateCcw className="h-4 w-4" /> Retry
            </button>
          </div>
        ) : (
          <>
            {/* top strip */}
            <div className="flex flex-col gap-4 rounded-xl border border-slate-200 bg-white p-5 shadow-sm sm:flex-row sm:items-center sm:justify-between">
              <div>
                <Label>MTCN</Label>
                <div className="font-mono text-xl font-semibold text-slate-900">{mtcn}</div>
                {caseData && <div className="text-sm text-slate-500">{caseData.corridor} · {caseData.amount.toLocaleString()} {caseData.currency}</div>}
              </div>
              <div className="flex flex-col items-start gap-2 sm:items-end">
                {g ? (
                  <div className={"inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-sm font-semibold ring-1 " + g.chip}>
                    <span className={"h-2 w-2 rounded-full " + g.dot} /> {g.label}
                    <span className="font-normal opacity-70">· {rec}{conf != null ? ` · ${Math.round(conf * 100)}%` : ""}</span>
                  </div>
                ) : (
                  <div className="inline-flex items-center gap-2 rounded-full bg-slate-100 px-3 py-1.5 text-sm text-slate-500 ring-1 ring-slate-200">
                    <Loader2 className="h-4 w-4 animate-spin" /> Grading…
                  </div>
                )}
                <div className="flex flex-wrap gap-1.5">
                  <AgentChip icon={Database} name="Data analysis" state={loading1 ? "run" : phase1 ? "done" : "idle"} />
                  <AgentChip icon={FileText} name="Document analysis" state={loading2 ? "run" : phase2 ? "done" : "idle"} />
                  <AgentChip icon={Scale} name="Grading" state={loading1 || loading2 ? "run" : phase1 ? "done" : "idle"} />
                </div>
              </div>
            </div>

            <div className="mt-6 grid gap-6 lg:grid-cols-5">
              {/* left: case data */}
              <div className="lg:col-span-2">
                <Card title="Case data" icon={Database} sub="From Snowflake">
                  {!caseData ? (
                    <Pending text="Fetching case…" />
                  ) : (
                    <>
                      <Label>Sender</Label>
                      <div className="mb-3 mt-1">
                        <div className="text-sm font-medium text-slate-800">{caseData.sender.name}</div>
                        <div className="text-xs text-slate-500">{caseData.sender.country} · {caseData.sender.id_type}</div>
                      </div>
                      <Label>Receiver</Label>
                      <div className="mb-3 mt-1">
                        <div className="text-sm font-medium text-slate-800">{caseData.receiver.name}</div>
                        <div className="text-xs text-slate-500">{caseData.receiver.country} · {caseData.receiver.id_type}</div>
                      </div>
                      <div className="mt-2 rounded-lg bg-slate-50 p-3 ring-1 ring-slate-100">
                        <KV k="Amount" v={`${caseData.amount.toLocaleString()} ${caseData.currency}`} mono />
                        <KV k="Channel" v={caseData.channel} />
                        <KV k="Transfers (30d)" v={caseData.history.transfers_30d} mono />
                        <KV k="Volume (30d)" v={`${caseData.history.total_30d_usd.toLocaleString()} ${caseData.currency}`} mono />
                      </div>
                      <div className="mt-3 rounded-lg bg-red-50 p-3 ring-1 ring-red-100">
                        <Label>Screening hit</Label>
                        <div className="mt-1 text-sm font-medium text-red-800">{caseData.gsi_hit.list}</div>
                        <div className="text-xs text-red-600">
                          match {Math.round(caseData.gsi_hit.match_score * 100)}% · fields: {caseData.gsi_hit.matched_fields.join(", ")}
                        </div>
                      </div>
                      {caseData.flags?.length > 0 && (
                        <ul className="mt-3 space-y-1.5">
                          {caseData.flags.map((f, i) => (
                            <li key={i} className="flex gap-2 text-xs text-slate-600">
                              <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-500" /> {f}
                            </li>
                          ))}
                        </ul>
                      )}
                    </>
                  )}
                </Card>
              </div>

              {/* right: analysis + upload + decision */}
              <div className="space-y-6 lg:col-span-3">
                <Card title="Data analysis" icon={Bot} sub="Transaction & case data">
                  {loading1 ? (
                    <Pending text="Reviewing transaction patterns, screening match, and history…" />
                  ) : phase1 ? (
                    <Analysis indicators={phase1.risk_indicators} rationale={phase1.rationale} />
                  ) : null}
                </Card>

                <Card title="Supporting documents" icon={Upload} sub="Any language — translated on analysis">
                  <input ref={fileRef} type="file" className="hidden" onChange={(e) => setFile(e.target.files?.[0] || null)} />
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
                    <button onClick={() => fileRef.current?.click()}
                      className="inline-flex items-center justify-center gap-2 rounded-lg border border-dashed border-slate-300 px-4 py-2.5 text-sm text-slate-600 transition hover:border-slate-400 hover:bg-slate-50">
                      <Upload className="h-4 w-4" /> {file ? "Change file" : "Choose file"}
                    </button>
                    {file && (
                      <div className="flex items-center gap-2 truncate text-sm text-slate-600">
                        <FileText className="h-4 w-4 shrink-0 text-teal-600" />
                        <span className="truncate">{file.name}</span>
                      </div>
                    )}
                    <button onClick={runDocument} disabled={!file || loading2 || !phase1}
                      className="ml-auto inline-flex items-center justify-center gap-2 rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40">
                      {loading2 ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
                      {loading2 ? "Analyzing…" : "Analyze document"}
                    </button>
                  </div>
                  <p className="mt-2 text-xs text-slate-400">PDF, image, or text. Non-English content is translated as part of the analysis.</p>

                  {docError && (
                    <div className="mt-3 flex items-center gap-2 rounded-md bg-red-50 px-3 py-2 text-xs text-red-700 ring-1 ring-red-200">
                      <AlertTriangle className="h-3.5 w-3.5" /> {docError}
                    </div>
                  )}
                  {loading2 && <div className="mt-4"><Pending text="Translating and analyzing the document, then re-grading…" /></div>}
                  {phase2 && (
                    <div className="mt-4 border-t border-slate-100 pt-4">
                      <div className="mb-2 flex flex-wrap items-center gap-2">
                        <span className="inline-flex items-center gap-1.5 rounded-md bg-teal-50 px-2 py-0.5 text-xs font-medium text-teal-700 ring-1 ring-teal-200">
                          <Languages className="h-3.5 w-3.5" /> {phase2.detected_language}
                        </span>
                        {phase2.grade_changed ? (
                          <span className="rounded-md bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-700 ring-1 ring-amber-200">Grade updated</span>
                        ) : (
                          <span className="rounded-md bg-slate-50 px-2 py-0.5 text-xs font-medium text-slate-500 ring-1 ring-slate-200">Grade unchanged</span>
                        )}
                      </div>
                      {phase2.document_summary && <p className="mb-3 text-sm text-slate-600">{phase2.document_summary}</p>}
                      <Analysis indicators={phase2.document_findings} rationale={phase2.change_reason} emptyLabel="No new risk findings from the document." />
                    </div>
                  )}
                </Card>

                {/* decision */}
                {!decision ? (
                  <div className="flex flex-col gap-3 rounded-xl border border-slate-200 bg-white p-5 shadow-sm sm:flex-row sm:items-center sm:justify-between">
                    <div className="text-sm text-slate-600">
                      <span className="font-medium text-slate-800">Analyst decision.</span> The grade is advisory — confirm to close the case.
                      {!phase2 && <span className="block text-xs text-slate-400">Tip: upload a document above for a fuller picture before deciding.</span>}
                    </div>
                    <div className="flex gap-2">
                      <button onClick={() => decide("DENIED")} disabled={!phase1}
                        className="inline-flex items-center gap-2 rounded-lg border border-red-200 bg-white px-4 py-2 text-sm font-medium text-red-700 transition hover:bg-red-50 disabled:opacity-40">
                        <XCircle className="h-4 w-4" /> Deny
                      </button>
                      <button onClick={() => decide("APPROVED")} disabled={!phase1}
                        className="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-40">
                        <CheckCircle2 className="h-4 w-4" /> Approve
                      </button>
                    </div>
                  </div>
                ) : (
                  <div className={"flex items-center justify-between gap-4 rounded-xl border p-5 shadow-sm " + (decision.action === "APPROVED" ? "border-emerald-200 bg-emerald-50" : "border-red-200 bg-red-50")}>
                    <div className="flex items-center gap-3">
                      {decision.action === "APPROVED" ? <CheckCircle2 className="h-8 w-8 text-emerald-600" /> : <XCircle className="h-8 w-8 text-red-600" />}
                      <div>
                        <div className={"text-lg font-semibold " + (decision.action === "APPROVED" ? "text-emerald-800" : "text-red-800")}>
                          Case {decision.action.toLowerCase()}
                        </div>
                        <div className="text-xs text-slate-500">Final grade {decision.grade} · {decision.ts}</div>
                      </div>
                    </div>
                    <button onClick={reset} className="inline-flex items-center gap-2 rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 transition hover:bg-slate-50">
                      <RotateCcw className="h-4 w-4" /> Start over
                    </button>
                  </div>
                )}
              </div>
            </div>
          </>
        )}
      </div>
      <Footer />
    </div>
  );
}
