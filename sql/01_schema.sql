-- ============================================================================
--  GBM ADVISORY · Plataforma de formación del asesor
--  Esquema de base de datos — PostgreSQL / Supabase
--  v1.0
--
--  Orden de ejecución:
--    1) schema.sql          (este archivo: tablas, vistas, seguridad)
--    2) seed_questions.sql   (carga las 29 secciones, 548 preguntas y opciones)
--
--  Modelo de datos (resumen):
--    cohorts ─< profiles ─< quiz_attempts ─< attempt_answers >─ questions ─< question_options
--    sections ─< questions
--
--  Notas de diseño al final del archivo.
-- ============================================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ---------------------------------------------------------------------------
--  Tipos
-- ---------------------------------------------------------------------------
create type user_role as enum ('advisor', 'trainer', 'admin');
create type quiz_mode as enum ('exam', 'practice');

-- ---------------------------------------------------------------------------
--  Cohortes (generaciones de la Ruta de Formación)
-- ---------------------------------------------------------------------------
create table cohorts (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,                 -- p.ej. 'Ruta Advisory · 2026 Q1'
  start_date  date,
  end_date    date,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
--  Perfiles  (1:1 con auth.users de Supabase Auth)
--  El asesor se autentica con Supabase; aquí guardamos su rol y cohorte.
-- ---------------------------------------------------------------------------
create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  email       text unique,
  role        user_role not null default 'advisor',
  cohort_id   uuid references cohorts(id) on delete set null,
  office      text,                          -- oficina / región (opcional)
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on profiles(cohort_id);
create index on profiles(role);

-- ---------------------------------------------------------------------------
--  Secciones (29 bloques temáticos del banco)
-- ---------------------------------------------------------------------------
create table sections (
  id          int primary key,               -- número de sección (1..29)
  title       text not null,
  area        text,                           -- agrupación macro para reportes
  sort_order  int not null
);

-- ---------------------------------------------------------------------------
--  Preguntas (id coincide con el banco: 1..548)
-- ---------------------------------------------------------------------------
create table questions (
  id            int primary key,
  section_id    int not null references sections(id),
  prompt        text not null,
  justification text not null,
  difficulty    smallint,                     -- 1..5 (opcional, para calibrar)
  is_active     boolean not null default true,
  version       int not null default 1,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on questions(section_id);

-- ---------------------------------------------------------------------------
--  Opciones de respuesta (normalizadas; permite analítica por distractor)
-- ---------------------------------------------------------------------------
create table question_options (
  id          bigint generated always as identity primary key,
  question_id int  not null references questions(id) on delete cascade,
  label       char(1) not null,               -- 'a'..'d' (orden canónico)
  body        text not null,
  is_correct  boolean not null default false,
  sort_order  int not null
);
create index on question_options(question_id);
-- Garantiza exactamente una opción correcta por pregunta:
create unique index one_correct_per_question
  on question_options(question_id) where is_correct;

-- ---------------------------------------------------------------------------
--  Intentos (un bloque/examen completado)
-- ---------------------------------------------------------------------------
create table quiz_attempts (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles(id) on delete cascade,
  mode             quiz_mode not null default 'exam',
  section_filter   int references sections(id),   -- null = todas las secciones
  is_certification boolean not null default false,
  num_questions    int not null,
  num_correct      int not null,
  score_pct        numeric(5,2) not null,
  duration_seconds int,
  started_at       timestamptz,
  finished_at      timestamptz not null default now()
);
create index on quiz_attempts(user_id, finished_at desc);
create index on quiz_attempts(is_certification) where is_certification;

-- ---------------------------------------------------------------------------
--  Respuestas (grano fino — tabla de hechos que alimenta TODA la analítica)
-- ---------------------------------------------------------------------------
create table attempt_answers (
  id               bigint generated always as identity primary key,
  attempt_id       uuid not null references quiz_attempts(id) on delete cascade,
  question_id      int  not null references questions(id),
  chosen_option_id bigint references question_options(id),
  is_correct       boolean not null,
  time_seconds     int,
  created_at       timestamptz not null default now()
);
create index on attempt_answers(attempt_id);
create index on attempt_answers(question_id);

-- ============================================================================
--  VISTAS DE ANALÍTICA  (lo que consume el panel administrativo)
-- ============================================================================

-- Progreso por asesor: intentos, aciertos, cobertura, última actividad
create or replace view v_user_progress as
with att as (
  select user_id,
         count(*)                  as attempts,
         round(avg(score_pct),1)   as avg_score,
         max(score_pct)            as best_score,
         max(finished_at)          as last_activity
  from quiz_attempts
  group by user_id
),
ans as (
  select a.user_id,
         count(*)                          as total_answered,
         sum(aa.is_correct::int)           as total_correct,
         count(distinct aa.question_id)    as unique_seen
  from attempt_answers aa
  join quiz_attempts a on a.id = aa.attempt_id
  group by a.user_id
)
select
  p.id                                       as user_id,
  p.full_name,
  p.cohort_id,
  p.is_active,
  coalesce(att.attempts, 0)                  as attempts,
  coalesce(att.avg_score, 0)                 as avg_score,
  coalesce(att.best_score, 0)                as best_score,
  coalesce(ans.unique_seen, 0)               as unique_seen,
  round(coalesce(ans.unique_seen,0)::numeric
        / nullif((select count(*) from questions where is_active), 0) * 100, 1) as coverage_pct,
  round(coalesce(ans.total_correct,0)::numeric
        / nullif(ans.total_answered, 0) * 100, 1)                               as accuracy_pct,
  att.last_activity
from profiles p
left join att on att.user_id = p.id
left join ans on ans.user_id = p.id
where p.role = 'advisor';

-- Dominio por asesor y sección (usa la ÚLTIMA respuesta de cada pregunta)
create or replace view v_user_section as
with last_ans as (
  select distinct on (a.user_id, aa.question_id)
         a.user_id, aa.question_id, q.section_id, aa.is_correct
  from attempt_answers aa
  join quiz_attempts a on a.id = aa.attempt_id
  join questions q     on q.id = aa.question_id
  order by a.user_id, aa.question_id, aa.created_at desc
)
select user_id, section_id,
       count(*)                                        as seen,
       round(sum(is_correct::int)::numeric / count(*) * 100, 1) as mastery_pct
from last_ans
group by user_id, section_id;

-- Dominio promedio por sección dentro de una cohorte (heatmap del panel)
create or replace view v_cohort_section as
select p.cohort_id, us.section_id,
       round(avg(us.mastery_pct), 1) as avg_mastery,
       count(distinct us.user_id)    as advisors_practiced
from v_user_section us
join profiles p on p.id = us.user_id
group by p.cohort_id, us.section_id;

-- Dificultad por pregunta (para mejorar el banco: % de acierto global)
create or replace view v_question_difficulty as
select q.id as question_id, q.section_id,
       count(aa.*)                                                   as times_answered,
       round(sum(aa.is_correct::int)::numeric / nullif(count(aa.*),0) * 100, 1) as pct_correct
from questions q
left join attempt_answers aa on aa.question_id = q.id
group by q.id, q.section_id;

-- Resumen por cohorte (tarjetas superiores del panel)
create or replace view v_cohort_overview as
select c.id as cohort_id, c.name,
       count(distinct p.id)            as advisors,
       round(avg(up.coverage_pct), 1)  as avg_coverage,
       round(avg(up.accuracy_pct), 1)  as avg_accuracy
from cohorts c
left join profiles p        on p.cohort_id = c.id and p.role = 'advisor'
left join v_user_progress up on up.user_id = p.id
group by c.id, c.name;

-- ============================================================================
--  RPC: registrar un intento y calificarlo EN EL SERVIDOR
--  El frontend envía solo {question_id, chosen_option_id}; la corrección se
--  determina aquí, de modo que la clave nunca tiene que viajar al cliente
--  (clave para exámenes de certificación).
-- ============================================================================
create or replace function record_attempt(
  p_mode            quiz_mode,
  p_section_filter  int,
  p_is_cert         boolean,
  p_duration        int,
  p_answers         jsonb   -- [{ "question_id": 12, "chosen_option_id": 345 }, ...]
) returns table (attempt_id uuid, num_correct int, num_questions int, score_pct numeric)
language plpgsql security definer as $$
declare
  v_attempt uuid;
  v_n int;
  v_correct int;
begin
  with a as (
    select (x->>'question_id')::int                    as qid,
           nullif(x->>'chosen_option_id','')::bigint   as oid
    from jsonb_array_elements(p_answers) x
  ),
  graded as (
    select a.qid, a.oid,
           coalesce((select o.is_correct from question_options o where o.id = a.oid), false) as ok
    from a
  )
  select count(*), sum(ok::int) into v_n, v_correct from graded;

  insert into quiz_attempts(user_id, mode, section_filter, is_certification,
                            num_questions, num_correct, score_pct, duration_seconds)
  values (auth.uid(), p_mode, p_section_filter, p_is_cert,
          v_n, v_correct, round(v_correct::numeric / nullif(v_n,0) * 100, 2), p_duration)
  returning id into v_attempt;

  insert into attempt_answers(attempt_id, question_id, chosen_option_id, is_correct)
  select v_attempt, g.qid, g.oid, g.ok
  from (
    select (x->>'question_id')::int as qid,
           nullif(x->>'chosen_option_id','')::bigint as oid,
           coalesce((select o.is_correct from question_options o
                     where o.id = nullif(x->>'chosen_option_id','')::bigint), false) as ok
    from jsonb_array_elements(p_answers) x
  ) g;

  return query
    select v_attempt, v_correct, v_n,
           round(v_correct::numeric / nullif(v_n,0) * 100, 2);
end;
$$;

-- ============================================================================
--  SEGURIDAD A NIVEL DE FILA (Row Level Security)
--  Un asesor solo ve/inserta lo suyo; staff (admin/trainer) ve todo.
-- ============================================================================
create or replace function is_staff() returns boolean
language sql stable security definer as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role in ('admin','trainer')
  );
$$;

alter table profiles        enable row level security;
alter table quiz_attempts   enable row level security;
alter table attempt_answers enable row level security;
alter table sections        enable row level security;
alter table questions       enable row level security;
alter table question_options enable row level security;
alter table cohorts         enable row level security;

-- Perfiles: cada quien ve el suyo; staff ve todos; cada quien edita el suyo.
create policy profiles_read   on profiles for select using (id = auth.uid() or is_staff());
create policy profiles_update on profiles for update using (id = auth.uid());

-- Intentos / respuestas: dueño (lectura/escritura) + staff (solo lectura amplia).
create policy attempts_rw on quiz_attempts for all
  using (user_id = auth.uid() or is_staff())
  with check (user_id = auth.uid());

create policy answers_rw on attempt_answers for all
  using (exists (select 1 from quiz_attempts a
                 where a.id = attempt_id and (a.user_id = auth.uid() or is_staff())))
  with check (exists (select 1 from quiz_attempts a
                      where a.id = attempt_id and a.user_id = auth.uid()));

-- Cohortes: legibles por staff (y por el asesor para mostrar su grupo).
create policy cohorts_read on cohorts for select using (true);

-- Catálogo (secciones / preguntas): legible por autenticados.
create policy sections_read  on sections  for select using (auth.role() = 'authenticated');
create policy questions_read on questions for select using (auth.role() = 'authenticated');

-- Opciones: legibles SIN exponer is_correct para práctica normal;
-- para certificación, NO leer opciones directo: calificar vía record_attempt().
-- Si se desea ocultar la clave por completo, restringir esta política a staff
-- y servir las opciones (sin is_correct) mediante una vista o función.
create policy options_read on question_options for select using (auth.role() = 'authenticated');

-- ============================================================================
--  NOTAS DE DISEÑO
--  · Carga del banco: ejecutar seed_questions.sql (generado del banco maestro).
--  · Migración desde la app actual: el export "progreso_gbm_advisory.json"
--    mapea a quiz_attempts (hist[]) y attempt_answers (stats por pregunta).
--  · Certificación con clave oculta: usar record_attempt() para calificar en el
--    servidor y NO exponer question_options.is_correct al rol 'advisor'
--    (cambiar options_read a is_staff() y exponer una vista sin is_correct).
--  · Reportes del panel: el panel administrativo consume v_user_progress,
--    v_cohort_overview, v_cohort_section y v_question_difficulty.
--  · Índices ya cubren los joins de las vistas; agregar índices adicionales
--    según volumen (p.ej. attempt_answers(question_id, is_correct)).
-- ============================================================================
