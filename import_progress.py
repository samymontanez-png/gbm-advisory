#!/usr/bin/env python3
# ============================================================================
#  GBM Advisory · Importación masiva de progreso local hacia Supabase
#
#  Sube a la base de datos los archivos "progreso_gbm_advisory.json" que los
#  asesores exportan desde la app (botón "Exportar progreso"). Llama a la
#  función import_progress_admin (restringida al service_role).
#
#  Requisitos (variables de entorno):
#    SUPABASE_URL          p.ej. https://tu-proyecto.supabase.co
#    SUPABASE_SERVICE_KEY  service_role key (Project Settings -> API)
#
#  Uso:
#    1) Un solo archivo:
#         python import_progress.py progreso_gbm_advisory.json <user_id_uuid>
#    2) Lote con manifiesto (CSV "archivo,user_id" por línea, sin encabezado):
#         python import_progress.py --manifest manifest.csv
#
#  El user_id es el id del perfil (auth.users.id) del asesor en Supabase.
# ============================================================================
import sys, os, json, csv, urllib.request, urllib.error

def call_import(url, key, user_id, data):
    payload = {"p_user": user_id,
               "p_hist": data.get("hist", []),
               "p_stats": data.get("stats", {})}
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/rpc/import_progress_admin",
        data=json.dumps(payload).encode("utf-8"),
        headers={"apikey": key, "Authorization": "Bearer " + key,
                 "Content-Type": "application/json"},
        method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")

def main():
    url = os.environ.get("SUPABASE_URL"); key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        sys.exit("Define SUPABASE_URL y SUPABASE_SERVICE_KEY en el entorno.")

    jobs = []  # (archivo, user_id)
    if len(sys.argv) >= 3 and sys.argv[1] == "--manifest":
        with open(sys.argv[2], encoding="utf-8") as f:
            for row in csv.reader(f):
                if len(row) >= 2 and row[0].strip():
                    jobs.append((row[0].strip(), row[1].strip()))
    elif len(sys.argv) >= 3:
        jobs.append((sys.argv[1], sys.argv[2]))
    else:
        sys.exit("Uso: python import_progress.py <export.json> <user_id>  |  --manifest <archivo.csv>")

    for path, uid in jobs:
        try:
            data = json.load(open(path, encoding="utf-8"))
        except Exception as e:
            print(f"[ERROR] {path}: no se pudo leer ({e})"); continue
        status, body = call_import(url, key, uid, data)
        name = data.get("name") or os.path.basename(path)
        print(f"[{status}] {name} -> {uid}: {body}")

if __name__ == "__main__":
    main()
