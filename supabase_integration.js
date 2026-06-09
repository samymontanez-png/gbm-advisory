/* ============================================================================
 *  GBM ADVISORY · Capa de integración con Supabase
 *  Conecta la app de estudio y el panel con el backend.
 *
 *  Requisitos en el HTML (antes de este archivo):
 *    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
 *
 *  Configura tus llaves (Project Settings → API en Supabase):
 * ==========================================================================*/
const SUPABASE_URL      = "https://TU-PROYECTO.supabase.co";
const SUPABASE_ANON_KEY = "TU-ANON-KEY";
const CERT_SERVICE_URL  = "https://TU-SERVICIO.onrender.com";  // servicio de PDF (carpeta server/)

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

/* Helper: ejecuta una RPC y devuelve data o lanza el error */
async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args || {});
  if (error) throw error;
  return data;
}

const GBM = {
  /* ---------------- Autenticación ---------------- */
  async signIn(email, password) {
    const { data, error } = await sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  },
  async signOut() { await sb.auth.signOut(); },
  async session() { return (await sb.auth.getSession()).data.session; },
  async profile() {
    const uid = (await sb.auth.getUser()).data.user.id;
    const { data, error } = await sb.from("profiles").select("*").eq("id", uid).single();
    if (error) throw error;
    return data;   // { full_name, role, cohort_id, ... }
  },

  /* ---------------- Práctica / examen ----------------
   * getQuestions devuelve reactivos SIN la clave:
   *   [{ id, section_id, prompt, options:[{id,label,body}] }, ...]
   */
  getQuestions(section = null, n = 20) { return rpc("get_questions", { p_section: section, p_n: n }); },

  /* Feedback inmediato de una respuesta (modo práctica). */
  async checkAnswer(questionId, optionId) {
    const r = await rpc("check_answer", { p_qid: questionId, p_oid: optionId });
    return r[0];   // { is_correct, correct_option_id, justification }
  },

  /* Registrar un bloque terminado. answers = [{question_id, chosen_option_id}] */
  async recordAttempt(mode, sectionFilter, isCert, durationSec, answers) {
    const r = await rpc("record_attempt", {
      p_mode: mode, p_section_filter: sectionFilter, p_is_cert: isCert,
      p_duration: durationSec, p_answers: answers
    });
    return r[0];   // { attempt_id, num_correct, num_questions, score_pct }
  },

  /* Revisión con justificaciones de un intento terminado. */
  attemptReview(attemptId) { return rpc("get_attempt_review", { p_attempt: attemptId }); },

  /* ---------------- Dashboard del asesor ---------------- */
  async myProgress()       { const r = await rpc("my_progress");        return r[0]; },
  mySectionMastery()       { return rpc("my_section_mastery"); },

  /* ---- Migración del progreso local (llamar UNA vez, justo después de signIn) ----
     Lee el localStorage de la app, lo sube con import_local_progress y, si se importó,
     limpia el almacenamiento local para no duplicar. Es idempotente en el servidor. */
  async migrateLocalProgress() {
    try {
      const hist  = JSON.parse(localStorage.getItem("gbm_adv_hist")  || "[]");
      const stats = JSON.parse(localStorage.getItem("gbm_adv_stats") || "{}");
      if ((hist && hist.length) || (stats && Object.keys(stats).length)) {
        const r = await rpc("import_local_progress", { p_hist: hist, p_stats: stats });
        if (r && r.imported) { localStorage.removeItem("gbm_adv_hist"); localStorage.removeItem("gbm_adv_stats"); }
        return r;
      }
      return { skipped: true, reason: "sin progreso local" };
    } catch (e) { console.warn("migración omitida:", e); return { error: String(e) }; }
  },

  /* ---------------- Certificación ---------------- */
  async certEligibility()  { const r = await rpc("cert_eligibility");   return r[0]; },
  /* start devuelve { num_questions, pass_pct, time_per_question_sec, questions:[...] } */
  startCertification()     { return rpc("start_certification"); },
  async submitCertification(durationSec, answers) {
    const r = await rpc("submit_certification", { p_duration: durationSec, p_answers: answers });
    return r[0];   // { passed, score_pct, num_correct, num_questions, pass_pct, certificate_code }
  },
  /* Enfoque híbrido: genera y GUARDA el PDF oficial en el servidor (server/). Devuelve { url, path }. */
  async emitCertificatePDF(payload) {
    const r = await fetch(CERT_SERVICE_URL.replace(/\/$/, "") + "/emitir", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    if (!r.ok) throw new Error("No se pudo emitir la constancia oficial");
    return r.json();
  },
  async verifyCertificate(folio) {
    const r = await fetch(CERT_SERVICE_URL.replace(/\/$/, "") + "/verificar/" + encodeURIComponent(folio));
    if (!r.ok) return { valid: false };
    return r.json();
  },

  /* ---------------- Panel administrativo (rol staff) ---------------- */
  async cohortOverview()       { const { data, error } = await sb.from("v_cohort_overview").select("*");                            if (error) throw error; return data; },
  async advisors(cohortId)     { let q = sb.from("v_user_progress").select("*"); if (cohortId) q = q.eq("cohort_id", cohortId);     const { data, error } = await q; if (error) throw error; return data; },
  async cohortSectionMastery(cohortId) { let q = sb.from("v_cohort_section").select("*"); if (cohortId) q = q.eq("cohort_id", cohortId); const { data, error } = await q; if (error) throw error; return data; },
  async hardestQuestions(limit = 10) { const { data, error } = await sb.from("v_question_difficulty").select("*").order("pct_correct", { ascending: true }).limit(limit); if (error) throw error; return data; },
  async certificationStatus(cohortId) { let q = sb.from("v_certification_status").select("*"); if (cohortId) q = q.eq("cohort_id", cohortId); const { data, error } = await q; if (error) throw error; return data; },
};

window.GBM = GBM;

/* ============================================================================
 *  CÓMO SE CONECTA CON LA APP ACTUAL
 *  La app hoy guarda en localStorage; con Supabase, al iniciar sesión:
 *
 *  1) Cargar reactivos en lugar del banco embebido:
 *       const qs = await GBM.getQuestions(seccion, 20);
 *       // cada opción trae .id (id real de la BD) — guarda el id elegido.
 *
 *  2) Práctica (feedback inmediato), al responder cada pregunta:
 *       const fb = await GBM.checkAnswer(q.id, opcionElegida.id);
 *       // fb.is_correct, fb.correct_option_id, fb.justification
 *
 *  3) Al terminar el bloque (reemplaza recordAttempt local):
 *       const answers = sesion.items.map(it => ({
 *         question_id: it.q.id,
 *         chosen_option_id: it.chosenOptionId   // null si no respondió
 *       }));
 *       const res = await GBM.recordAttempt('exam', seccion, false, segundos, answers);
 *       // res.score_pct, res.num_correct, res.attempt_id
 *       const review = await GBM.attemptReview(res.attempt_id); // para la pantalla de revisión
 *
 *  4) Dashboard "Mi progreso" (en vez de leer localStorage):
 *       const p = await GBM.myProgress();          // KPIs del asesor
 *       const cob = await GBM.mySectionMastery();  // cobertura/dominio por sección
 *
 *  FLUJO DE CERTIFICACIÓN
 *       const elig = await GBM.certEligibility();
 *       if (!elig.can_attempt) { ... mostrar intentos restantes o periodo de espera ... }
 *       const exam = await GBM.startCertification();      // reactivos sin clave + reglas
 *       // ...el asesor responde contra reloj (exam.time_per_question_sec * exam.num_questions)...
 *       const answers = [...]; // [{question_id, chosen_option_id}]
 *       const r = await GBM.submitCertification(segundos, answers);
 *       if (r.passed) mostrarConstancia(r.certificate_code, r.score_pct);
 *       else mostrarNoAprobado(r.score_pct, r.pass_pct);
 *
 *  PANEL ADMINISTRATIVO (reemplaza los datos de demostración)
 *       const kpis     = await GBM.cohortOverview();
 *       const lista    = await GBM.advisors(cohortId);
 *       const temas    = await GBM.cohortSectionMastery(cohortId);
 *       const dificiles= await GBM.hardestQuestions(8);
 *       const certs    = await GBM.certificationStatus(cohortId);
 * ==========================================================================*/
