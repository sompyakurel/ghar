# Ghar Backend — run this on your Mac

The Python API that serves lesson content to the iOS app.

## Run it

```bash
cd ~/Desktop/Ghar/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Then open **http://localhost:8000/docs** — free interactive API playground.
Try `GET /packs/nepal-v1` to see the exact JSON the iPhone app downloads.

Keep this Terminal window open while you run the iOS app — the app
calls `http://localhost:8000`, and the simulator shares your Mac's network.

## What's here

- `app/main.py` — the FastAPI app: 5 endpoints
- `app/schemas.py` — Pydantic models (the data contract shared with Swift)
- `app/data/nepal-v1.json` — first content pack: 3 decks, 12 words, Tihar quest
- `requirements.txt` — fastapi, uvicorn, pydantic
