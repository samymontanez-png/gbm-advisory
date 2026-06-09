-- ============================================================================
--  GBM ADVISORY · Llamadas de la app cableada (calificación por etiqueta)
--  Ejecutar después de platform_calls_certification.sql
--
--  La app de estudio usa el banco embebido y conoce la etiqueta (a/b/c/d) de la
--  opción elegida, no el id interno. Estas funciones califican EN EL SERVIDOR a
--  partir de la etiqueta, de modo que cobertura, dominio y certificación queden
--  registrados de forma autoritativa sin exponer la clave en el cliente.
--
--  payload p_answers: [{ "question_id": 12, "label": "b" }, ...]  (label null = sin responder)
-- ============================================================================

-- Registrar un bloque (práctica o examen) calificando por etiqueta
create or replace function record_attempt_labels(
  p_mode quiz_mode, p_section_filter int, p_is_cert boolean,
  p_duration int, p_answers jsonb)
returns table(attempt_id uuid, num_correct int, num_questions int, score_pct numeric)
language plpgsql security definer
set search_path = public as $$
declare v_attempt uuid; v_n int; v_correct int;
begin
  with a as (
    select (x->>'question_id')::int qid, nullif(x->>'label','') lbl
    from jsonb_array_elements(p_answers) x
  )
  select count(*),
         sum((coalesce((select o.is_correct from question_options o
                        where o.question_id = a.qid and o.label = a.lbl), false))::int)
    into v_n, v_correct
  from a;

  insert into quiz_attempts(user_id, mode, section_filter, is_certification,
                            num_questions, num_correct, score_pct, duration_seconds)
  values (auth.uid(), p_mode, p_section_filter, p_is_cert,
          v_n, v_correct, round(v_correct::numeric / nullif(v_n,0) * 100, 2), p_duration)
  returning id into v_attempt;

  insert into attempt_answers(attempt_id, question_id, chosen_option_id, is_correct)
  select v_attempt, a.qid,
         (select o.id from question_options o where o.question_id = a.qid and o.label = a.lbl),
         coalesce((select o.is_correct from question_options o where o.question_id = a.qid and o.label = a.lbl), false)
  from (select (x->>'question_id')::int qid, nullif(x->>'label','') lbl
        from jsonb_array_elements(p_answers) x) a;

  return query select v_attempt, v_correct, v_n, round(v_correct::numeric / nullif(v_n,0) * 100, 2);
end;
$$;

-- Enviar examen de certificación calificando por etiqueta + emitir folio si aprueba
create or replace function submit_certification_labels(p_duration int, p_answers jsonb)
returns table(passed boolean, score_pct numeric, num_correct int, num_questions int,
              pass_pct numeric, certificate_code text)
language plpgsql security definer
set search_path = public as $$
declare cfg cert_config; v_attempt uuid; v_n int; v_correct int; v_pct numeric; v_pass boolean; v_code text;
begin
  select * into cfg from cert_config where id = 1;

  with a as (
    select (x->>'question_id')::int qid, nullif(x->>'label','') lbl
    from jsonb_array_elements(p_answers) x
  )
  select count(*),
         sum((coalesce((select o.is_correct from question_options o
                        where o.question_id = a.qid and o.label = a.lbl), false))::int)
    into v_n, v_correct
  from a;

  v_pct  := round(v_correct::numeric / nullif(v_n,0) * 100, 2);
  v_pass := v_pct >= cfg.pass_pct;

  insert into quiz_attempts(user_id, mode, is_certification, num_questions, num_correct, score_pct, duration_seconds)
  values (auth.uid(), 'exam', true, v_n, v_correct, v_pct, p_duration)
  returning id into v_attempt;

  insert into attempt_answers(attempt_id, question_id, chosen_option_id, is_correct)
  select v_attempt, a.qid,
         (select o.id from question_options o where o.question_id = a.qid and o.label = a.lbl),
         coalesce((select o.is_correct from question_options o where o.question_id = a.qid and o.label = a.lbl), false)
  from (select (x->>'question_id')::int qid, nullif(x->>'label','') lbl
        from jsonb_array_elements(p_answers) x) a;

  if v_pass then
    v_code := 'GBM-ADV-' || to_char(now(),'YYYY') || '-' || upper(substr(encode(gen_random_bytes(4),'hex'),1,6));
    insert into certifications(user_id, attempt_id, score_pct, passed, certificate_code)
    values (auth.uid(), v_attempt, v_pct, true, v_code);
  end if;

  return query select v_pass, v_pct, v_correct, v_n, cfg.pass_pct, v_code;
end;
$$;
