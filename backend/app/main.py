"""
Ghar backend — serves versioned content packs to the iOS app.

Teaching notes for Som:
- FastAPI turns each @app.get function below into a real HTTP endpoint.
  Run the server, visit http://localhost:8000/docs, and you get a free
  interactive API playground — great for testing what the app will call.
- Pydantic (schemas.py) validates every pack at load time. Bad JSON =
  loud 500 error here, not a silent broken screen on a kid's phone.
- Packs are versioned files (nepal-v1.json, nepal-v2.json...). New words
  ship by adding a file — the app downloads it, no App Store review wait.
"""
from pathlib import Path
import json

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles

from .schemas import ContentPack

app = FastAPI(title="Ghar API", version="0.1.0")

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
