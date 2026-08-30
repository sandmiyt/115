import asyncio
import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from urllib.parse import urlencode, urlparse

import httpx
from cryptography.fernet import Fernet
from fastapi import FastAPI, Form, HTTPException, Query
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

APP = FastAPI(title="Cineva 115 Authorization Service", docs_url=None, redoc_url=None)
app = APP

CLIENT_ID = os.environ.get("CINEVA_115_CLIENT_ID", "").strip()
CLIENT_SECRET = os.environ.get("CINEVA_115_CLIENT_SECRET", "").strip()
PUBLIC_BASE_URL = os.environ.get("CINEVA_115_PUBLIC_BASE_URL", "").strip().rstrip("/")
APP_CALLBACK_URL = os.environ.get(
    "CINEVA_115_APP_CALLBACK_URL", "cineva115://oauth/115"
).strip()
SIGNING_SECRET = os.environ.get("CINEVA_AUTH_SIGNING_SECRET", "").encode("utf-8")
DB_PATH = os.environ.get("CINEVA_AUTH_DB", "/data/cineva-auth.sqlite3")
REFRESH_CACHE_TTL = 24 * 60 * 60
STATE_TTL = 10 * 60
AUTH_SESSION_TTL = 5 * 60
REFRESH_URL = "https://qrcodeapi.115.com/open/refreshToken"
AUTHORIZE_URL = "https://qrcodeapi.115.com/open/authorize"
TOKEN_URL = "https://qrcodeapi.115.com/open/authCodeToToken"
_refresh_lock = asyncio.Lock()
_session_lock = asyncio.Lock()


def _require_config() -> None:
    if (
        not CLIENT_ID
        or not CLIENT_SECRET
        or not PUBLIC_BASE_URL
        or len(SIGNING_SECRET) < 24
    ):
        raise HTTPException(status_code=503, detail="Cineva 115 authorization service is not configured")
    if not PUBLIC_BASE_URL.lower().startswith("https://"):
        raise HTTPException(status_code=503, detail="CINEVA_115_PUBLIC_BASE_URL must use HTTPS")
    callback = urlparse(APP_CALLBACK_URL)
    if callback.scheme.lower() != "cineva115":
        raise HTTPException(status_code=503, detail="CINEVA_115_APP_CALLBACK_URL must use cineva115://")


def _fernet() -> Fernet:
    key = base64.urlsafe_b64encode(hashlib.sha256(SIGNING_SECRET).digest())
    return Fernet(key)


@contextmanager
def _db():
    directory = os.path.dirname(DB_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    try:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS refresh_cache ("
            "old_hash TEXT PRIMARY KEY, encrypted_response BLOB NOT NULL, created_at INTEGER NOT NULL)"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS authorization_sessions ("
            "ticket_hash TEXT PRIMARY KEY, encrypted_response BLOB NOT NULL, created_at INTEGER NOT NULL)"
        )
        yield conn
        conn.commit()
    finally:
        conn.close()


def _token_hash(token: str) -> str:
    return hmac.new(SIGNING_SECRET, token.encode("utf-8"), hashlib.sha256).hexdigest()


def _cache_get(old_hash: str):
    cutoff = int(time.time()) - REFRESH_CACHE_TTL
    with _db() as conn:
        conn.execute("DELETE FROM refresh_cache WHERE created_at < ?", (cutoff,))
        row = conn.execute(
            "SELECT encrypted_response FROM refresh_cache WHERE old_hash = ?", (old_hash,)
        ).fetchone()
    if not row:
        return None
    try:
        return json.loads(_fernet().decrypt(row[0]).decode("utf-8"))
    except Exception:
        return None


def _cache_put(old_hash: str, payload: dict) -> None:
    encrypted = _fernet().encrypt(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    with _db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO refresh_cache(old_hash, encrypted_response, created_at) VALUES(?,?,?)",
            (old_hash, encrypted, int(time.time())),
        )


def _authorization_session_put(payload: dict) -> str:
    ticket = secrets.token_urlsafe(32)
    encrypted = _fernet().encrypt(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    with _db() as conn:
        conn.execute(
            "INSERT INTO authorization_sessions(ticket_hash, encrypted_response, created_at) "
            "VALUES(?,?,?)",
            (_token_hash(ticket), encrypted, int(time.time())),
        )
    return ticket


def _authorization_session_take(ticket: str):
    cutoff = int(time.time()) - AUTH_SESSION_TTL
    ticket_hash = _token_hash(ticket)
    with _db() as conn:
        conn.execute("DELETE FROM authorization_sessions WHERE created_at < ?", (cutoff,))
        row = conn.execute(
            "SELECT encrypted_response FROM authorization_sessions WHERE ticket_hash = ?",
            (ticket_hash,),
        ).fetchone()
        if row:
            conn.execute(
                "DELETE FROM authorization_sessions WHERE ticket_hash = ?", (ticket_hash,)
            )
    if not row:
        return None
    try:
        return json.loads(_fernet().decrypt(row[0]).decode("utf-8"))
    except Exception:
        return None


def _make_state() -> str:
    payload = f"{int(time.time())}.{secrets.token_urlsafe(18)}"
    sig = hmac.new(SIGNING_SECRET, payload.encode("utf-8"), hashlib.sha256).digest()
    return payload + "." + base64.urlsafe_b64encode(sig).decode("ascii").rstrip("=")


def _verify_state(state: str) -> bool:
    try:
        ts, nonce, sig_text = state.split(".", 2)
        if abs(int(time.time()) - int(ts)) > STATE_TTL:
            return False
        payload = f"{ts}.{nonce}"
        expected = hmac.new(SIGNING_SECRET, payload.encode("utf-8"), hashlib.sha256).digest()
        supplied = base64.urlsafe_b64decode(sig_text + "=" * (-len(sig_text) % 4))
        return hmac.compare_digest(expected, supplied)
    except Exception:
        return False


def _extract_token_payload(obj: dict) -> dict:
    payload = obj.get("data") if isinstance(obj.get("data"), dict) else obj
    access = str(payload.get("access_token") or "").strip()
    refresh = str(payload.get("refresh_token") or "").strip()
    if not access or not refresh:
        code = obj.get("errno", obj.get("code", 0))
        message = obj.get("error") or obj.get("message") or "115 authorization failed"
        raise HTTPException(status_code=401, detail={"code": code, "message": message})
    result = {"access_token": access, "refresh_token": refresh}
    expires = payload.get("expires_in")
    if expires is not None:
        result["expires_in"] = expires
    return result


@app.get("/health")
async def health():
    return {"status": "ok", "service": "cineva-115-auth"}


@app.get("/115cloud/requests")
async def create_authorization_request():
    _require_config()
    redirect_uri = PUBLIC_BASE_URL + "/115cloud/callback"
    state = _make_state()
    url = AUTHORIZE_URL + "?" + urlencode(
        {
            "client_id": CLIENT_ID,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "state": state,
        }
    )
    response = JSONResponse({"state": True, "text": url})
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/115cloud/callback")
async def authorization_callback(code: str = Query(""), state: str = Query("")):
    _require_config()
    if not code or not _verify_state(state):
        raise HTTPException(status_code=400, detail="Invalid authorization callback")

    redirect_uri = PUBLIC_BASE_URL + "/115cloud/callback"
    async with httpx.AsyncClient(timeout=20.0, follow_redirects=False) as client:
        response = await client.post(
            TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "code": code,
                "redirect_uri": redirect_uri,
            },
            headers={"User-Agent": "Cineva-Auth/1.0"},
        )
    try:
        obj = response.json()
    except Exception as exc:
        raise HTTPException(status_code=502, detail="Invalid response from 115") from exc
    token_payload = _extract_token_payload(obj)
    ticket = _authorization_session_put(token_payload)
    separator = "&" if "?" in APP_CALLBACK_URL else "?"
    callback_url = APP_CALLBACK_URL + separator + urlencode({"ticket": ticket})
    return RedirectResponse(callback_url, status_code=302)


@app.post("/115cloud/session")
async def exchange_authorization_ticket(ticket: str = Form(...)):
    _require_config()
    normalized = ticket.strip()
    if not normalized:
        raise HTTPException(status_code=400, detail="ticket is required")
    async with _session_lock:
        payload = _authorization_session_take(normalized)
    if payload is None:
        raise HTTPException(status_code=401, detail="Authorization ticket is invalid or expired")
    return JSONResponse({"state": True, "data": payload}, headers={"Cache-Control": "no-store"})


@app.get("/115cloud/complete")
async def authorization_complete():
    return HTMLResponse(
        "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<body style='font-family:-apple-system;padding:32px;text-align:center'>"
        "115 授权已完成，可以返回 Cineva。</body>",
        headers={"Cache-Control": "no-store"},
    )


@app.post("/115cloud/refresh")
async def refresh_token(refresh_token: str = Form(...)):
    _require_config()
    token = refresh_token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="refresh_token is required")
    old_hash = _token_hash(token)

    cached = _cache_get(old_hash)
    if cached is not None:
        return JSONResponse({"state": True, "data": cached}, headers={"Cache-Control": "no-store"})

    async with _refresh_lock:
        cached = _cache_get(old_hash)
        if cached is not None:
            return JSONResponse({"state": True, "data": cached}, headers={"Cache-Control": "no-store"})

        async with httpx.AsyncClient(timeout=20.0) as client:
            try:
                response = await client.post(
                    REFRESH_URL,
                    data={"refresh_token": token},
                    headers={"User-Agent": "Cineva-Auth/1.0"},
                )
            except httpx.HTTPError as exc:
                # Crucially, do not make a second upstream refresh call here. The old
                # token may already have been consumed by 115.
                raise HTTPException(status_code=503, detail="115 refresh transport failure") from exc

        try:
            obj = response.json()
        except Exception as exc:
            raise HTTPException(status_code=502, detail="Invalid refresh response from 115") from exc

        payload_obj = obj.get("data") if isinstance(obj.get("data"), dict) else obj
        access = str(payload_obj.get("access_token") or "").strip()
        new_refresh = str(payload_obj.get("refresh_token") or "").strip()
        if access and new_refresh:
            result = {"access_token": access, "refresh_token": new_refresh}
            if payload_obj.get("expires_in") is not None:
                result["expires_in"] = payload_obj.get("expires_in")
            _cache_put(old_hash, result)
            return JSONResponse({"state": True, "data": result}, headers={"Cache-Control": "no-store"})

        code = obj.get("errno", obj.get("code", 0))
        message = obj.get("error") or obj.get("message") or "115 refresh failed"
        status = 429 if int(code or 0) == 40140117 else 401 if int(code or 0) in {
            40140114, 40140115, 40140116, 40140119, 40140120
        } else 502
        return JSONResponse(
            {"state": False, "code": code, "message": message},
            status_code=status,
            headers={"Cache-Control": "no-store"},
        )
