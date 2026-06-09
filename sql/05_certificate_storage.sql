-- ============================================================================
--  GBM ADVISORY · Almacenamiento y verificación de constancias (enfoque híbrido)
--  Ejecutar después de platform_calls_certification.sql
-- ============================================================================

-- 1) Ruta del PDF oficial almacenado en Storage
alter table certifications add column if not exists pdf_path text;

-- 2) Bucket privado para las constancias (el servicio sube con service_role)
insert into storage.buckets (id, name, public)
values ('constancias', 'constancias', false)
on conflict (id) do nothing;
-- Nota: el service_role omite RLS, por lo que el servicio puede subir y firmar
-- URLs sin políticas adicionales. Si quieres permitir descarga directa por el
-- propio asesor, agrega una política de lectura sobre storage.objects.

-- 3) Verificación pública por folio (no expone datos sensibles)
create or replace function verify_certificate(p_code text)
returns table(valid boolean, full_name text, score_pct numeric, issued_at timestamptz)
language sql security definer
set search_path = public as $$
  select true, p.full_name, c.score_pct, c.issued_at
  from certifications c
  join profiles p on p.id = c.user_id
  where c.certificate_code = p_code and c.passed
  limit 1;
$$;
grant execute on function verify_certificate(text) to anon, authenticated;
