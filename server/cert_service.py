# -*- coding: utf-8 -*-
# ============================================================================
#  GBM Advisory · Servicio de emisión de constancias (PDF)
#  FastAPI + WeasyPrint. Renderiza la constancia oficial, la sube a Supabase
#  Storage y guarda la ruta en la tabla certifications.
#
#  Variables de entorno requeridas:
#    SUPABASE_URL          https://tu-proyecto.supabase.co
#    SUPABASE_SERVICE_KEY  service_role key
#    CERT_BUCKET           (opcional) nombre del bucket, por defecto "constancias"
#
#  Endpoints:
#    POST /emitir          { name, folio, score, date?, program? }  -> { url, path }
#    GET  /verificar/{folio}                                        -> { valid, ... }
#    GET  /salud
# ============================================================================
import os, json, datetime, urllib.request, urllib.error
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from weasyprint import HTML

BASE         = Path(__file__).parent
TEMPLATE     = (BASE / "cert_template.html").read_text(encoding="utf-8")
SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY  = os.environ["SUPABASE_SERVICE_KEY"]
BUCKET       = os.environ.get("CERT_BUCKET", "constancias")

MESES = ["enero","febrero","marzo","abril","mayo","junio","julio","agosto",
         "septiembre","octubre","noviembre","diciembre"]

app = FastAPI(title="GBM Advisory · Constancias")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class CertReq(BaseModel):
    name: str
    folio: str
    score: str | int | None = None
    date: str | None = None
    program: str = "Ruta de Formación · GBM Advisory"

def esc(s): return (str(s) if s is not None else "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
def hoy():
    d = datetime.date.today(); return f"{d.day} de {MESES[d.month-1]} de {d.year}"
def score_str(s):
    if s is None or s == "": return "—"
    s = str(s); return s if s.endswith("%") else s + "%"

def render_pdf(req: CertReq) -> bytes:
    html = (TEMPLATE
            .replace("__NAME__",    esc(req.name))
            .replace("__FOLIO__",   esc(req.folio))
            .replace("__DATE__",    esc(req.date or hoy()))
            .replace("__SCORE__",   esc(score_str(req.score)))
            .replace("__PROGRAM__", esc(req.program)))
    return HTML(string=html, base_url=str(BASE)).write_pdf()

def supa(method, path, data=None, headers=None):
    h = {"apikey": SERVICE_KEY, "Authorization": "Bearer " + SERVICE_KEY}
    if headers: h.update(headers)
    req = urllib.request.Request(SUPABASE_URL + path, data=data, headers=h, method=method)
    with urllib.request.urlopen(req) as r:
        body = r.read()
        return body

@app.get("/salud")
def salud(): return {"ok": True}

@app.post("/emitir")
def emitir(req: CertReq):
    try:
        pdf = render_pdf(req)
        # 1) Subir (upsert) a Storage
        supa("POST", f"/storage/v1/object/{BUCKET}/{req.folio}.pdf",
             data=pdf, headers={"Content-Type": "application/pdf", "x-upsert": "true"})
        # 2) URL firmada de larga duración (1 año)
        signed = json.loads(supa("POST", f"/storage/v1/object/sign/{BUCKET}/{req.folio}.pdf",
                 data=json.dumps({"expiresIn": 31536000}).encode(),
                 headers={"Content-Type": "application/json"}))
        url = SUPABASE_URL + "/storage/v1" + signed["signedURL"]
        # 3) Guardar la ruta en certifications
        try:
            supa("PATCH", f"/rest/v1/certifications?certificate_code=eq.{req.folio}",
                 data=json.dumps({"pdf_path": f"{BUCKET}/{req.folio}.pdf"}).encode(),
                 headers={"Content-Type": "application/json", "Prefer": "return=minimal"})
        except urllib.error.HTTPError:
            pass  # si el folio aún no existe en BD, igual devolvemos el PDF
        return {"url": url, "path": f"{BUCKET}/{req.folio}.pdf"}
    except urllib.error.HTTPError as e:
        raise HTTPException(status_code=e.code, detail=e.read().decode("utf-8", "ignore"))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/verificar/{folio}")
def verificar(folio: str):
    try:
        res = json.loads(supa("POST", "/rest/v1/rpc/verify_certificate",
              data=json.dumps({"p_code": folio}).encode(),
              headers={"Content-Type": "application/json"}))
    except urllib.error.HTTPError as e:
        raise HTTPException(status_code=e.code, detail=e.read().decode("utf-8", "ignore"))
    if not res:
        raise HTTPException(status_code=404, detail="Folio no encontrado")
    return res[0]
