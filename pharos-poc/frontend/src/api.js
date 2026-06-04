const BASE = import.meta.env.VITE_API_URL || "http://localhost:8000";

async function readError(res) {
  try {
    const j = await res.json();
    return j.detail || j.message || null;
  } catch {
    return null;
  }
}

export async function analyzeCase(mtcn) {
  const res = await fetch(`${BASE}/api/cases/${encodeURIComponent(mtcn)}/analyze`, {
    method: "POST",
  });
  if (!res.ok) throw new Error((await readError(res)) || `Analyze failed (${res.status})`);
  return res.json(); // { case, analysis }
}

export async function analyzeDocument(mtcn, file, priorGrade) {
  const fd = new FormData();
  fd.append("file", file);
  if (priorGrade) fd.append("prior_grade", priorGrade);
  const res = await fetch(`${BASE}/api/cases/${encodeURIComponent(mtcn)}/documents`, {
    method: "POST",
    body: fd,
  });
  if (!res.ok) throw new Error((await readError(res)) || `Document analysis failed (${res.status})`);
  return res.json(); // { analysis }
}

export async function recordDecision(mtcn, action, grade) {
  const fd = new FormData();
  fd.append("action", action);
  if (grade) fd.append("grade", grade);
  try {
    await fetch(`${BASE}/api/cases/${encodeURIComponent(mtcn)}/decision`, {
      method: "POST",
      body: fd,
    });
  } catch {
    /* non-blocking in the POC */
  }
}
