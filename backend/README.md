# Ghar Backend

The Python API that serves lesson content to the iOS app. This is your
backend codebase, Som — we'll grow it together, and every piece maps to
a real DevOps skill (APIs, validation, versioning, and later: Docker,
CI, and cloud deploys).

## What's here

- `app/main.py` — the FastAPI app: 5 endpoints (`/health`, `/packs`, pack/deck/quest lookups)
- `app/schemas.py` — Pydantic models: the data contract shared with the iOS app
- `app/data/nepal-v1.json` — the first content pack: 3 decks (12 words) + the Tihar quest
- `requirements.txt` — Python dependencies

## Run it (your hands-on part)

```bash
cd ~/workspace/heritage-app/backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Then open **http://localhost:8000/docs** — FastAPI gives you a free
interactive API playground. Try `GET /packs/nepal-v1` and you'll see the
exact JSON the iPhone app will download.

## Teaching map (how this grows with you)

1. **Now:** REST API + Pydantic validation (you're here)
2. **Next:** serve the family-recorded `.m4a` files from `/audio/...`
3. **Then:** Dockerfile + GitHub Actions (build/test on every push)
4. **Later:** deploy to a small cloud VM; the iOS app points at the live URL

## Content workflow (family recordings)

1. Family records one phrase per file on iPhone Voice Memos
2. Name it exactly like the `audio_url` in the JSON, e.g. `food_momo_np.m4a`
3. Drop it in `app/static/audio/nepal-v1/` (we'll wire up static serving next)
4. One fluent elder reviews pronunciation → merge

## API quick reference

| Method | Path | What it returns |
|--------|------|-----------------|
| GET | `/health` | `{"status": "ok"}` |
| GET | `/packs` | list of available packs |
| GET | `/packs/{pack_id}` | full pack (decks + quests) |
| GET | `/packs/{pack_id}/decks/{deck_id}` | one deck with its words |
| GET | `/packs/{pack_id}/quests/{quest_id}` | one quest with its scenes |
