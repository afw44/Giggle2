from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Body, HTTPException
from fastapi.responses import JSONResponse
from typing import Dict, Set, List, Any, Optional
from uuid import uuid4
import re
import asyncio

app = FastAPI()

# ---------- Realtime ----------
connections: Dict[str, Set[WebSocket]] = {}

def add_conn(user_id: str, ws: WebSocket) -> None:
    connections.setdefault(user_id, set()).add(ws)

def remove_conn(user_id: str, ws: WebSocket) -> None:
    if user_id in connections:
        connections[user_id].discard(ws)
        if not connections[user_id]:
            del connections[user_id]

async def send_to_user(user_id: str, payload: dict) -> None:
    for ws in list(connections.get(user_id, [])):
        try:
            await ws.send_json(payload)
        except Exception:
            pass

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    user_id = ws.query_params.get("user_id")
    if not user_id:
        await ws.close(code=4000)
        return
    await ws.accept()
    add_conn(user_id, ws)
    print("WS CONNECTED:", user_id)
    try:
        while True:
            # keepalive; ignore incoming messages
            await ws.receive_text()
    except WebSocketDisconnect:
        remove_conn(user_id, ws)
        print("WS DISCONNECTED:", user_id)

@app.get("/health")
def health():
    return {"ok": True}

# ---------- Gigs (in-memory) ----------
GENTS: List[str] = ["gent-1", "gent-2", "gent-3", "gent-4", "gent-5"]

# gigs store: id -> {id, date, client_email, fee}
gigs: Dict[str, Dict[str, Any]] = {}

# assignments: gig_id -> set(gent-ids)
gig_assignments: Dict[str, Set[str]] = {}

_email_rx = re.compile(r"^[^@]+@[^@]+\.[^@]+$")

def ensure_gig(gig_id: str) -> Dict[str, Any]:
    g = gigs.get(gig_id)
    if not g:
        raise HTTPException(status_code=404, detail="gig not found")
    return g

@app.post("/gigs", status_code=201)
def create_gig(
    date: str = Body(..., embed=True),           # "YYYY-MM-DD"
    client_email: str = Body(..., embed=True),
    fee: int = Body(..., embed=True)             # integer (e.g., cents)
):
    if not _email_rx.match(client_email):
        raise HTTPException(status_code=400, detail="invalid email")
    gid = str(uuid4())
    gigs[gid] = {"id": gid, "date": date, "client_email": client_email, "fee": fee}
    gig_assignments[gid] = set()
    return gigs[gid]

@app.get("/gigs")
def list_gigs():
    out: List[Dict[str, Any]] = []
    for gid, g in gigs.items():
        out.append({**g, "gents": sorted(list(gig_assignments.get(gid, set())))})
    return {"gigs": out}

@app.patch("/gigs/{gig_id}")
def update_gig(
    gig_id: str,
    date: Optional[str] = Body(None, embed=True),
    client_email: Optional[str] = Body(None, embed=True),
    fee: Optional[int] = Body(None, embed=True),
):
    g = ensure_gig(gig_id)
    if date is not None:
        g["date"] = date
    if client_email is not None:
        if not _email_rx.match(client_email):
            raise HTTPException(status_code=400, detail="invalid email")
        g["client_email"] = client_email
    if fee is not None:
        g["fee"] = fee
    # notify assigned gents that gigs changed
    for gent in gig_assignments.get(gig_id, set()):
        asyncio.create_task(send_to_user(gent, {"type": "gigs_changed"}))
    return g

@app.post("/gigs/{gig_id}/assign")
async def assign_gent(
    gig_id: str,
    gent_id: str = Body(..., embed=True),
    assigned: bool = Body(..., embed=True),
):
    if gent_id not in GENTS:
        raise HTTPException(status_code=404, detail="unknown gent id")
    _ = ensure_gig(gig_id)
    s = gig_assignments.setdefault(gig_id, set())
    before = gent_id in s
    if assigned:
        s.add(gent_id)
    else:
        s.discard(gent_id)
    changed = (before != assigned)
    if changed:
        await send_to_user(gent_id, {"type": "gigs_changed"})
    return {"id": gig_id, "gents": sorted(list(s))}

@app.get("/manager/gigs")
def manager_gigs():
    return list_gigs()

@app.get("/gent/{gent_id}/gigs")
def gigs_for_gent(gent_id: str):
    if gent_id not in GENTS:
        raise HTTPException(status_code=404, detail="unknown gent id")
    result: List[Dict[str, Any]] = []
    for gid, g in gigs.items():
        if gent_id in gig_assignments.get(gid, set()):
            result.append(g)
    # sort by date then id for stable output
    result.sort(key=lambda x: (x.get("date", ""), x["id"]))
    return {"gigs": result}


"""
source .venv/bin/activate
uvicorn app:app --reload --host 127.0.0.1 --port 8000
"""