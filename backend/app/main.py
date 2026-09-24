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

from .schemas import ContentPack

app = FastAPI(title="Ghar API", version="0.1.0")

DATA_DIR = Path(__file__).parent / "data"


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
