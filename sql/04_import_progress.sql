-- ============================================================================
--  GBM ADVISORY · Importación del progreso local hacia la base de datos
--  Ejecutar después de schema.sql / seed_questions.sql / platform_calls_certification.sql
--
--  La app guarda en localStorage:
--    gbm_adv_hist  -> [{ts,mode,n,correct,pct,dur,sec}, ...]   (bloques)
--    gbm_adv_stats -> { "<id>": {sec,seen,correct,last,first} } (estado por pregunta)
--  y la opción "Exportar progreso" descarga { name, hist, stats }.
--
--  Estrategia de mapeo:
--   · Cada bloque de 'hist' se inserta como una fila en quiz_attempts (historial/tendencia).
--   · El estado por pregunta de 'stats' se materializa como UN intento de "migración"
--     con sus attempt_answers (is_correct = último resultado conocido), de modo que la
--     cobertura y el dominio por sección queden correctos en las vistas.
-- ============================================================================

-- ---------------------------------------------------------------------------
--  Núcleo reutilizable: inserta el progreso para un usuario dado
-- ---------------------------------------------------------------------------
create or replace function _import_progress(p_user uuid, p_hist jsonb, p_stats jsonb)
returns jsonb
language plpgsql security definer
set search_path = public as $$
declare v_attempt uuid; v_seen int; v_correct int; v_blocks int;
begin
  if p_user is null then raise exception 'user_id requerido'; end if;

  -- Idempotencia: no reimportar si el usuario ya tiene intentos
  if exists (select 1 from quiz_attempts where user_id = p_user) then
    return jsonb_build_object('skipped', true, 'reason', 'el usuario ya tiene intentos');
  end if;

  -- 1) Historial de bloques -> quiz_attempts
  insert into quiz_attempts(user_id, mode, section_filter, num_questions, num_correct,
                            score_pct, duration_seconds, finished_at)
  select p_user,
         (case when (h->>'mode') = 'practica' then 'practice' else 'exam' end)::quiz_mode,
         nullif((h->>'sec')::int, 0),
         (h->>'n')::int, (h->>'correct')::int, (h->>'pct')::numeric, (h->>'dur')::int,
         to_timestamp((h->>'ts')::bigint / 1000.0)
  from jsonb_array_elements(coalesce(p_hist, '[]'::jsonb)) h;
  get diagnostics v_blocks = row_count;

  -- 2) Estado por pregunta -> intento de migración + attempt_answers
  select count(*), sum(((v->>'last')::boolean)::int)
    into v_seen, v_correct
  from jsonb_each(coalesce(p_stats, '{}'::jsonb)) as e(k, v)
  where exists (select 1 from questions q where q.id = (e.k)::int);

  if coalesce(v_seen,0) > 0 then
    insert into quiz_attempts(user_id, mode, num_questions, num_correct, score_pct, finished_at)
    values (p_user, 'practice', v_seen, coalesce(v_correct,0),
            round(coalesce(v_correct,0)::numeric / v_seen * 100, 2), now())
    returning id into v_attempt;

    insert into attempt_answers(attempt_id, question_id, chosen_option_id, is_correct)
    select v_attempt, (e.k)::int,
           case when (v->>'last')::boolean
                then (select o.id from question_options o where o.question_id = (e.k)::int and o.is_correct)
                else null end,
           (v->>'last')::boolean
    from jsonb_each(coalesce(p_stats, '{}'::jsonb)) as e(k, v)
    where exists (select 1 from questions q where q.id = (e.k)::int);
  end if;

  return jsonb_build_object('imported', true, 'blocks', coalesce(v_blocks,0), 'questions', coalesce(v_seen,0));
end;
$$;

-- ---------------------------------------------------------------------------
--  A) Auto-migración del propio asesor (la app la llama tras iniciar sesión)
-- ---------------------------------------------------------------------------
create or replace function import_local_progress(p_hist jsonb, p_stats jsonb)
returns jsonb
language sql security definer
set search_path = public as $$
  select _import_progress(auth.uid(), p_hist, p_stats);
$$;

-- ---------------------------------------------------------------------------
--  B) Importación masiva por staff / backend (desde archivos exportados)
--     Restringida al service_role (la usa el script import_progress.py).
-- ---------------------------------------------------------------------------
create or replace function import_progress_admin(p_user uuid, p_hist jsonb, p_stats jsonb)
returns jsonb
language sql security definer
set search_path = public as $$
  select _import_progress(p_user, p_hist, p_stats);
$$;

revoke execute on function import_progress_admin(uuid, jsonb, jsonb) from public, anon, authenticated;
grant  execute on function import_progress_admin(uuid, jsonb, jsonb) to service_role;

-- Nota: se crea un intento de "migración" (mode='practice') que transporta el detalle
-- por pregunta. Si se prefiere no contarlo como intento en los KPIs, se puede marcar con
-- una columna/etiqueta y excluirlo en las vistas.
