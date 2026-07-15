-- ============================================================================
--  GBM ADVISORY · Plataforma de formación
--  Llamadas de la app (RPC) + lógica de certificación
--  Ejecutar DESPUÉS de schema.sql y seed_questions.sql
--
--  Idea clave de seguridad: la CLAVE de respuestas (question_options.is_correct)
--  nunca se expone al asesor. La app pide reactivos SIN clave y la corrección
--  ocurre en el servidor (funciones SECURITY DEFINER). Así el examen de
--  certificación no se puede "leer" desde el navegador.
-- ============================================================================

-- ---------------------------------------------------------------------------
--  1) Endurecer el acceso a la clave de respuestas
--     (sustituye la política permisiva options_read del schema base)
-- ---------------------------------------------------------------------------
drop policy if exists options_read on question_options;
create policy options_staff_read on question_options
  for select using (is_staff());      -- solo admin/trainer leen la tabla con is_correct

-- ---------------------------------------------------------------------------
--  2) Entrega de reactivos SIN clave (práctica y examen)
-- ---------------------------------------------------------------------------
create or replace function get_questions(p_section int default null, p_n int default 20)
returns jsonb
language sql security definer stable
set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'section_id', t.section_id, 'prompt', t.prompt, 'options', t.options)), '[]'::jsonb)
  from (
    select q.id, q.section_id, q.prompt,
      (select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'body', o.body) order by o.sort_order)
       from question_options o where o.question_id = q.id) as options
    from questions q
    where q.is_active and (p_section is null or q.section_id = p_section)
    order by random()
    limit greatest(1, least(p_n, 100))
  ) t;
$$;

-- ---------------------------------------------------------------------------
--  3) Feedback inmediato de una respuesta (modo práctica)
--     Devuelve si acertó + cuál era la correcta + la justificación.
-- ---------------------------------------------------------------------------
create or replace function check_answer(p_qid int, p_oid bigint)
returns table(is_correct boolean, correct_option_id bigint, justification text)
language sql security definer stable
set search_path = public as $$
  select
    coalesce((select o.is_correct from question_options o where o.id = p_oid and o.question_id = p_qid), false),
    (select o.id from question_options o where o.question_id = p_qid and o.is_correct),
    (select q.justification from questions q where q.id = p_qid);
$$;

-- ---------------------------------------------------------------------------
--  4) Registrar un bloque (práctica o examen) — corrige en el servidor
--     (record_attempt se define en schema.sql; aquí solo se documenta su uso)
--     payload: [{ "question_id": 12, "chosen_option_id": 345 }, ...]
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
--  5) Revisión de un intento terminado (justificaciones al final)
-- ---------------------------------------------------------------------------
create or replace function get_attempt_review(p_attempt uuid)
returns table(question_id int, prompt text, chosen_option_id bigint, is_correct boolean,
              correct_option_id bigint, justification text)
language sql security definer stable
set search_path = public as $$
  select aa.question_id, q.prompt, aa.chosen_option_id, aa.is_correct,
         (select o.id from question_options o where o.question_id = aa.question_id and o.is_correct),
         q.justification
  from attempt_answers aa
  join quiz_attempts a on a.id = aa.attempt_id
  join questions q     on q.id = aa.question_id
  where aa.attempt_id = p_attempt and (a.user_id = auth.uid() or is_staff());
$$;

-- ---------------------------------------------------------------------------
--  6) Dashboard del propio asesor (su fila, sin ver a los demás)
-- ---------------------------------------------------------------------------
create or replace function my_progress()
returns table(attempts int, avg_score numeric, best_score numeric, unique_seen int,
              coverage_pct numeric, accuracy_pct numeric, last_activity timestamptz)
language sql security definer stable
set search_path = public as $$
  select up.attempts, up.avg_score, up.best_score, up.unique_seen,
         up.coverage_pct, up.accuracy_pct, up.last_activity
  from v_user_progress up where up.user_id = auth.uid();
$$;

create or replace function my_section_mastery()
returns table(section_id int, seen int, mastery_pct numeric)
language sql security definer stable
set search_path = public as $$
  select section_id, seen, mastery_pct from v_user_section where user_id = auth.uid();
$$;

-- ============================================================================
--  CERTIFICACIÓN
-- ============================================================================

-- Configuración (una sola fila editable por staff)
create table if not exists cert_config (
  id                    int primary key default 1,
  num_questions         int  not null default 100,
  pass_pct              numeric(5,2) not null default 80,
  time_per_question_sec int  not null default 60,
  max_attempts          int  not null default 3,
  cooldown_hours        int  not null default 24,
  check (id = 1)
);
insert into cert_config(id) values (1) on conflict do nothing;
update cert_config set num_questions = 100, time_per_question_sec = 60 where id = 1;

-- Certificaciones emitidas
create table if not exists certifications (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles(id) on delete cascade,
  attempt_id       uuid references quiz_attempts(id),
  score_pct        numeric(5,2) not null,
  passed           boolean not null,
  certificate_code text unique,            -- folio de la constancia
  issued_at        timestamptz not null default now()
);
create index if not exists certifications_user_idx on certifications(user_id);

alter table cert_config    enable row level security;
alter table certifications enable row level security;
create policy cert_config_read   on cert_config    for select using (auth.role() = 'authenticated');
create policy cert_config_write  on cert_config    for all    using (is_staff()) with check (is_staff());
create policy cert_self          on certifications for select using (user_id = auth.uid() or is_staff());

-- Estado de elegibilidad (cuántos intentos lleva, si puede reintentar)
create or replace function cert_eligibility()
returns table(attempts_used int, max_attempts int, certified boolean, can_attempt boolean, next_attempt_at timestamptz)
language plpgsql security definer stable
set search_path = public as $$
declare cfg cert_config; used int; lasttry timestamptz; cert boolean;
begin
  select * into cfg from cert_config where id = 1;
  select count(*), max(finished_at) into used, lasttry
    from quiz_attempts where user_id = auth.uid() and is_certification;
  select exists(select 1 from certifications where user_id = auth.uid() and passed) into cert;
  return query select
    used, cfg.max_attempts, cert,
    (not cert) and used < cfg.max_attempts
      and (lasttry is null or now() >= lasttry + make_interval(hours => cfg.cooldown_hours)),
    case when lasttry is null then null else lasttry + make_interval(hours => cfg.cooldown_hours) end;
end;
$$;

-- Iniciar examen de certificación: entrega reactivos SIN clave + valida reglas
create or replace function start_certification()
returns jsonb
language plpgsql security definer
set search_path = public as $$
declare cfg cert_config; elig record;
begin
  select * into cfg from cert_config where id = 1;
  select * into elig from cert_eligibility();
  if elig.certified then
    raise exception 'Ya cuentas con la certificación vigente.';
  end if;
  if not elig.can_attempt then
    raise exception 'No puedes iniciar el examen ahora (intentos: %/%, o periodo de espera activo).',
      elig.attempts_used, elig.max_attempts;
  end if;
  return jsonb_build_object(
    'num_questions', cfg.num_questions,
    'pass_pct', cfg.pass_pct,
    'time_per_question_sec', cfg.time_per_question_sec,
    'questions', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', t.id, 'section_id', t.section_id, 'prompt', t.prompt, 'options', t.options)), '[]'::jsonb)
      from (
        select q.id, q.section_id, q.prompt,
          (select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'body', o.body) order by o.sort_order)
           from question_options o where o.question_id = q.id) as options
        from questions q where q.is_active
        order by random() limit cfg.num_questions
      ) t
    )
  );
end;
$$;

-- Enviar y calificar el examen de certificación (servidor) + emitir folio si aprueba
create or replace function submit_certification(p_duration int, p_answers jsonb)
returns table(passed boolean, score_pct numeric, num_correct int, num_questions int,
              pass_pct numeric, certificate_code text)
language plpgsql security definer
set search_path = public as $$
declare cfg cert_config; v_attempt uuid; v_n int; v_correct int; v_pct numeric; v_pass boolean; v_code text;
begin
  select * into cfg from cert_config where id = 1;

  with g as (
    select nullif(x->>'chosen_option_id','')::bigint as oid
    from jsonb_array_elements(p_answers) x
  )
  select count(*),
         sum((coalesce((select o.is_correct from question_options o where o.id = g.oid), false))::int)
    into v_n, v_correct
  from g;

  v_pct  := round(v_correct::numeric / nullif(v_n,0) * 100, 2);
  v_pass := v_pct >= cfg.pass_pct;

  insert into quiz_attempts(user_id, mode, is_certification, num_questions, num_correct, score_pct, duration_seconds)
  values (auth.uid(), 'exam', true, v_n, v_correct, v_pct, p_duration)
  returning id into v_attempt;

  insert into attempt_answers(attempt_id, question_id, chosen_option_id, is_correct)
  select v_attempt, (x->>'question_id')::int, nullif(x->>'chosen_option_id','')::bigint,
         coalesce((select o.is_correct from question_options o
                   where o.id = nullif(x->>'chosen_option_id','')::bigint), false)
  from jsonb_array_elements(p_answers) x;

  if v_pass then
    v_code := 'GBM-ADV-' || to_char(now(),'YYYY') || '-' || upper(substr(encode(gen_random_bytes(4),'hex'),1,6));
    insert into certifications(user_id, attempt_id, score_pct, passed, certificate_code)
    values (auth.uid(), v_attempt, v_pct, true, v_code);
  end if;

  return query select v_pass, v_pct, v_correct, v_n, cfg.pass_pct, v_code;
end;
$$;

-- Estado de certificación por asesor (para el panel administrativo)
create or replace view v_certification_status as
select p.id as user_id, p.full_name, p.cohort_id,
       count(qa.*) filter (where qa.is_certification)              as cert_attempts,
       coalesce(bool_or(c.passed), false)                          as certified,
       max(c.score_pct) filter (where c.passed)                    as best_cert_score,
       max(c.issued_at) filter (where c.passed)                    as certified_at,
       (array_agg(c.certificate_code order by c.issued_at desc)
          filter (where c.passed))[1]                              as certificate_code
from profiles p
left join quiz_attempts  qa on qa.user_id = p.id and qa.is_certification
left join certifications c  on c.user_id  = p.id
where p.role = 'advisor'
group by p.id, p.full_name, p.cohort_id;

-- ============================================================================
--  NOTAS
--  · Reglas de certificación: se editan en cert_config (preguntas, % para
--    aprobar, tiempo por pregunta, intentos máximos, horas de espera).
--  · Antifraude: la clave nunca llega al cliente; los reactivos se barajan en
--    cada intento y se toman al azar del banco. Para alto rigor, sumar
--    proctoring y un pool de reactivos exclusivo de certificación.
--  · El panel administrativo puede consumir v_certification_status para la
--    tarjeta "Certificables/Certificados".
-- ============================================================================
