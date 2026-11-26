"""
Ghar backend — serves versioned content packs to the iOS app.

Teaching notes for Som:
- FastAPI turns each @app.get function below into a real HTTP endpoint.
  (The free /docs playground is disabled in production since 2026-11-12;
  see the FastAPI(...) call below to re-enable it locally.)
- Pydantic (schemas.py) validates every pack at load time. Bad JSON =
  loud 500 error here, not a silent broken screen on a kid's phone.
- Packs are versioned files (nepal-v1.json, nepal-v2.json...). New words
  ship by adding a file — the app downloads it, no App Store review wait.
"""
from pathlib import Path
import json
import os
import uuid

from fastapi import FastAPI, HTTPException, Request, UploadFile, File, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from .schemas import ContentPack
from .leaderboard import router as leaderboard_router
from .calendar import router as calendar_router
from .accounts import router as accounts_router
from .ask import router as ask_router
from .games import router as games_router
from .stripe_pay import router as stripe_router
from .digest import router as digest_router

app = FastAPI(
    title="Ghar API",
    version="0.1.0",
    # Audit M1 (2026-11-12): the interactive docs, ReDoc and the raw
    # OpenAPI schema are OFF in production — they hand anyone a map of
    # every endpoint. For a local testing session, remove these three
    # arguments and /docs comes back.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
# The web (CloudFront) calls this API from the browser, so it needs CORS.
# Auth is a Bearer token in a header (not a cookie), so the web origin is safe.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://d2ie4a5rdlljd6.cloudfront.net",
        "https://gharlearn.com",
        "https://www.gharlearn.com",
    ],
    allow_methods=["*"],
    allow_headers=["*"],
)
# Audit L3 (2026-11-13): no endpoint takes a large body - the biggest
# legitimate payload is a progress or layout save, a few KB. Reject
# anything over 256 KB up front instead of buffering it into memory
# on the smallest machine size. (Bodies sent chunked, without a
# Content-Length, are not measured here; every field is still
# length-capped by pydantic after parsing.)
@app.middleware("http")
async def _limit_body_size(request: Request, call_next):
    # Board uploads (/board/upload) are legitimately large (GIF ~1-2 MB,
    # MP4 ~5-6 MB) — the endpoint enforces its own 20 MB cap, so skip
    # the 256 KB limit here.
    if request.url.path == "/board/upload":
        return await call_next(request)
    cl = request.headers.get("content-length")
    if cl:
        try:
            if int(cl) > 262144:
                return JSONResponse(status_code=413, content={"detail": "Request too large"})
        except ValueError:
            pass
    return await call_next(request)


app.include_router(leaderboard_router)
# Calendar router REMOVED 2026-11-12 at Som's word: the /calendar
# endpoint published his personal calendar's event titles to anyone
# with the link (it existed for a TV dashboard that is no longer in
# use). calendar.py stays in the repo, unused, if the TV ever returns
# — behind an unguessable address next time.
app.include_router(accounts_router)
app.include_router(ask_router)
app.include_router(games_router)
app.include_router(stripe_router)
app.include_router(digest_router)

# Nightly database backup to S3 (app/backup.py). Inert until the AWS
# credentials exist as Fly secrets; a backup failure never reaches
# the app. Started here so every cold start re-arms the timer.
try:
    from .backup import start_backup_thread
    start_backup_thread()
except Exception as _e:  # pragma: no cover
    print(f"[backup] thread not started: {_e}")

# Weekly parent digest email (app/digest.py). Opt-in only; the
# thread is inert outside its Sunday/Monday send window, and a
# failure never reaches the app.
try:
    from .digest import start_digest_thread
    start_digest_thread()
except Exception as _e:  # pragma: no cover
    print(f"[digest] thread not started: {_e}")

# Porch board (Memory Wall / Who's Here) file hosting.
# The board driver uploads a GIF (phone/TV) and an MP4 (Echo Show via
# Voice Monkey) each time a family member is recognised. These need a
# public URL that Voice Monkey's cloud, the phone, and the TV can fetch.
# Remote-storage uploads trigger a per-upload approval card, which breaks
# the automatic board — so the board files live here instead, on Som's
# own backend. Upload requires a Bearer token (BOARD_UPLOAD_TOKEN env var);
# GETs are unauthenticated but the filenames carry a random UUID, so the
# URLs are unguessable. Files live on Fly's ephemeral filesystem — they
# only need to last until the next arrival overwrites them.
BOARD_DIR = Path(__file__).parent / "static" / "board"
BOARD_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/board", StaticFiles(directory=BOARD_DIR), name="board")
BOARD_UPLOAD_TOKEN = os.environ.get("BOARD_UPLOAD_TOKEN", "")


@app.post("/board/upload")
async def upload_board_file(
    file: UploadFile = File(...),
    authorization: str = Header(default=""),
):
    """Upload a board GIF or MP4. Returns the public URL."""
    if not BOARD_UPLOAD_TOKEN:
        raise HTTPException(status_code=503, detail="Board uploads not configured")
    if authorization != f"Bearer {BOARD_UPLOAD_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid board upload token")
    suffix = Path(file.filename or "").suffix.lower()
    if suffix not in {".gif", ".mp4", ".jpg", ".jpeg", ".png"}:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {suffix}")
    name = f"{uuid.uuid4().hex}{suffix}"
    dest = BOARD_DIR / name
    data = await file.read()
    if len(data) > 20 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="File too large (max 20 MB)")
    dest.write_bytes(data)
    return {"url": f"/board/{name}", "filename": name}


DATA_DIR = Path(__file__).parent / "data"

# Family-recorded audio lives here, organized to match the audio_url paths
# in the JSON:  audio_url "/audio/nepal-v1/food_momo_np.m4a"
#        <-->  file app/static/audio/nepal-v1/food_momo_np.m4a
# Drop a new .m4a in the right folder and the app can play it immediately —
# no code changes, no app update.
AUDIO_DIR = Path(__file__).parent / "static" / "audio"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/audio", StaticFiles(directory=AUDIO_DIR), name="audio")

# Animal photos live here as base64 text files (pushed from the VM, which has
# no binary channel to this Mac). One request -> decode once -> serve JPEG.
# JSON image paths like "/images/nepal-v1/anim_kukur.jpg" map to
#   app/static/images_b64/anim_kukur.jpg.b64
import base64
from fastapi import Response

IMAGES_B64_DIR = Path(__file__).parent / "static" / "images_b64"
IMAGES_B64_DIR.mkdir(parents=True, exist_ok=True)


@app.get("/images/nepal-v1/{name}.jpg")
def serve_image(name: str):
    path = IMAGES_B64_DIR / f"{name}.jpg.b64"
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Image '{name}' not found")
    data = base64.b64decode(path.read_text(encoding="ascii"))
    return Response(content=data, media_type="image/jpeg")


def load_pack(pack_id: str) -> ContentPack:
    path = DATA_DIR / f"{pack_id}.json"
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Pack '{pack_id}' not found")
    raw = json.loads(path.read_text(encoding="utf-8"))
    return ContentPack(**raw)  # validation happens here


@app.get("/health")
def health():
    return {"status": "ok"}


# Public web pages: the App Store listing links a live Privacy Policy URL
# and a Support URL. Plain files in app/static/pages/, no templating.
PAGES_DIR = Path(__file__).parent / "static" / "pages"


@app.get("/privacy")
def privacy_page():
    return FileResponse(PAGES_DIR / "privacy-policy.html", media_type="text/html")


@app.get("/support")
def support_page():
    return FileResponse(PAGES_DIR / "support.html", media_type="text/html")


@app.get("/")
def landing_page():
    return FileResponse(PAGES_DIR / "landing.html", media_type="text/html")


@app.get("/packs")
def list_packs():
    """Which countries/languages are available?"""
    packs = sorted(p.stem for p in DATA_DIR.glob("*.json"))
    return {"packs": packs}


@app.get("/packs/{pack_id}", response_model=ContentPack)
def get_pack(pack_id: str):
    """Full pack: every deck + quest. The app caches this on first launch."""
    return load_pack(pack_id)


@app.get("/packs/{pack_id}/decks/{deck_id}")
def get_deck(pack_id: str, deck_id: str):
    pack = load_pack(pack_id)
    for deck in pack.decks:
        if deck.id == deck_id:
            return deck
    raise HTTPException(status_code=404, detail=f"Deck '{deck_id}' not found")


@app.get("/packs/{pack_id}/quests/{quest_id}")
def get_quest(pack_id: str, quest_id: str):
    pack = load_pack(pack_id)
    for quest in pack.quests:
        if quest.id == quest_id:
            return quest
    raise HTTPException(status_code=404, detail=f"Quest '{quest_id}' not found")
