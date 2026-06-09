# GBM Advisory · Plataforma de formación

Ecosistema de formación y certificación de asesores: app de estudio, panel
académico, base de datos con seguridad por roles y emisión de constancias en PDF
(**enfoque híbrido**: descarga inmediata desde el navegador + PDF oficial generado
y archivado en el servidor).

## Cómo se reparte el despliegue

| Componente | Vive en | Qué hace |
|---|---|---|
| Frontend (raíz: `index.html`, panel, constancia, JS) | **GitHub Pages** (estático) | App de estudio, panel académico, generador de constancia |
| Base de datos (`sql/`) | **Supabase** (Postgres + Auth + Storage) | Preguntas, intentos, certificaciones, vistas, seguridad |
| Servicio de PDF (`server/`) | **Render** (u otro host con Docker) | Genera la constancia oficial y la guarda en Storage |

## Estructura del repositorio

```
.
├── index.html                       App de estudio (autónoma; práctica + certificación)
├── Panel_Admin_GBM_Advisory.html    Panel académico (demo / en vivo)
├── Certificado_GBM_Advisory.html    Generador de constancia (descarga en el navegador)
├── supabase_integration.js          Capa de llamadas a Supabase + servicio de PDF
├── import_progress.py               Importación masiva de progreso local (opcional)
├── sql/
│   ├── 01_schema.sql                Tablas, vistas, RLS, record_attempt
│   ├── 02_seed_questions.sql        Carga del banco (29 secciones, 548 preguntas)
│   ├── 03_platform_calls_certification.sql   RPC de la app + certificación
│   ├── 04_import_progress.sql       Migración del progreso local
│   ├── 05_certificate_storage.sql   Almacenamiento y verificación de constancias
│   └── 06_app_label_calls.sql       Calificación por etiqueta (app cableada)
└── server/
    ├── cert_service.py              API (FastAPI) que emite el PDF
    ├── cert_template.html           Plantilla del diploma (server-side)
    ├── requirements.txt
    ├── Dockerfile
    └── assets/                      Fuentes GBMSans + logos para el PDF
```

---

## Paso 1 — Base de datos en Supabase

1. Crea un proyecto en https://supabase.com
2. En **SQL Editor**, ejecuta en orden los archivos de `sql/`:
   `01_schema.sql` → `02_seed_questions.sql` → `03_platform_calls_certification.sql`
   → `04_import_progress.sql` → `05_certificate_storage.sql` → `06_app_label_calls.sql`
   (El paso 05 crea el bucket privado `constancias`.)
3. Crea tu usuario de staff: en **Authentication → Users** agrega tu correo; luego en
   **SQL Editor** inserta tu perfil:
   ```sql
   insert into profiles (id, full_name, email, role)
   values ('<tu-user-id-uuid>', 'Samuel Montañez', 'tu@correo.com', 'admin');
   ```
4. En **Project Settings → API** copia: `Project URL`, `anon public key` y `service_role key`.

## Paso 2 — Servicio de PDF en Render

1. En https://render.com → **New → Web Service** y conecta este repositorio.
2. Configura: **Root Directory** = `server`, **Runtime** = `Docker`.
3. En **Environment** agrega las variables:
   - `SUPABASE_URL` = tu Project URL
   - `SUPABASE_SERVICE_KEY` = tu service_role key
4. Despliega. Copia la URL pública del servicio (p. ej. `https://gbm-constancias.onrender.com`).
5. Pruébalo: `GET https://…/salud` debe responder `{"ok": true}`.

## Paso 3 — Configurar el frontend

Edita y guarda:

- **`index.html`** (app de estudio) — busca el bloque *CONFIGURACIÓN* cerca del inicio del `<script>`:
  ```js
  const SUPABASE_URL      = "https://tu-proyecto.supabase.co";
  const SUPABASE_ANON_KEY = "tu-anon-key";
  const CERT_SERVICE_URL  = "https://gbm-constancias.onrender.com";
  ```
  Con llaves reales, la app pide inicio de sesión y guarda todo en Supabase; con `TU-`, sigue autónoma.
- **`supabase_integration.js`** (arriba del archivo):
  ```js
  const SUPABASE_URL      = "https://tu-proyecto.supabase.co";
  const SUPABASE_ANON_KEY = "tu-anon-key";
  const CERT_SERVICE_URL  = "https://gbm-constancias.onrender.com";
  ```
- **`Panel_Admin_GBM_Advisory.html`** (en el bloque de configuración del `<script>`):
  pon tu `SUPABASE_URL` y `SUPABASE_ANON_KEY`. Mientras tengan `TU-`, el panel sigue en
  modo demostración.

## Paso 4 — Publicar el frontend en GitHub Pages

1. Sube todo el repositorio a GitHub (rama `main`).
2. **Settings → Pages**: *Source* = **Deploy from a branch**, rama `main`, carpeta `/ (root)`.
3. En ~1 min tendrás la URL pública. Ahí cargan:
   - `…/` → app de estudio (`index.html`)
   - `…/Panel_Admin_GBM_Advisory.html` → panel académico
   - `…/Certificado_GBM_Advisory.html` → constancia

> GitHub Pages solo sirve los archivos estáticos de la raíz; la carpeta `server/`
> queda en el repo únicamente para que Render la despliegue.

## Paso 5 — Migración del progreso local (opcional)

- **Automática:** en la versión conectada, tras iniciar sesión la app llama
  `GBM.migrateLocalProgress()` (en `supabase_integration.js`) y sube el avance del navegador.
- **Masiva:** con los archivos `progreso_gbm_advisory.json` que exporten los asesores,
  define `SUPABASE_URL` y `SUPABASE_SERVICE_KEY` en tu terminal y corre:
  ```
  python import_progress.py progreso_gbm_advisory.json <user_id>
  # o por lote:  python import_progress.py --manifest manifest.csv
  ```

---

## Flujo híbrido de certificación (de punta a punta)

1. El asesor presenta el examen y, al aprobar, `submit_certification()` (en Supabase)
   califica en el servidor y **emite el folio** oficial.
2. El navegador ofrece **descarga inmediata** del PDF (`Certificado_GBM_Advisory.html`,
   botón *Descargar PDF*).
3. En paralelo, la app llama `GBM.emitCertificatePDF({ name, folio, score, date })`, que
   pide al **servicio** el PDF oficial; este lo genera con el mismo diseño, lo **guarda en
   Storage** (`constancias/{folio}.pdf`) y registra la ruta en `certifications`.
4. Cualquiera puede **verificar** un folio: `GET https://…/verificar/{folio}` (o la función
   `verify_certificate` en SQL).

## Estado actual

- La **app de estudio** (`index.html`) ya está **cableada**: sin llaves funciona autónoma
  (práctica, progreso local, certificación con descarga de PDF); con llaves pide inicio de
  sesión y opera en vivo —registra cada bloque, migra el progreso local al entrar, muestra el
  dashboard desde el servidor y, al certificar, emite el folio y archiva el PDF oficial.
- El **panel** funciona en demostración y pasa a datos reales al configurar las llaves.
- Todo el ciclo queda en vivo una vez ejecutada la SQL, desplegado el servicio y puestas las llaves.

## Notas

- Las constancias se guardan en un bucket **privado**; el servicio entrega una URL firmada.
- El examen de certificación nunca expone la clave de respuestas: se califica en el servidor.
- Reglas de certificación (nº de preguntas, % para aprobar, intentos): tabla `cert_config`.
