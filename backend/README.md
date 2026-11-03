# Ghar Backend

The FastAPI service behind Ghar: Learn Nepali. It serves the content packs
the iOS app is built from, the family leaderboard API, and the support,
privacy, and landing web pages.

Production runs on Fly.io. The shipped iOS app does NOT fetch content from
here at runtime — content is bundled into the app at build time by
`ios/BundleContent.sh`. The live backend matters for the leaderboard and
the web pages.

## What's here

- `app/main.py` — the FastAPI app: pack endpoints, web pages, static files
- `app/leaderboard.py` — group scores: create/join groups, post scores, delete
- `app/schemas.py` — Pydantic models (the data contract shared with Swift)
- `app/data/nepal-v1.json` — 22 lesson decks, 342 words
- `app/data/songs-v1.json` — 3 songs
- `app/data/rhymes-v1.json` — 3 rhymes
- `app/static/audio/` — base word audio (`.m4a`)
- `app/static/audio_b64/` — voice-clone audio (`.m4a.b64`), decoded over the base files at build time
- `app/static/images_b64/` — word images, decoded at build time
- `app/static/images/myghar/` — My Ghar room decorations
- `app/static/pages/` — support / privacy / landing pages

## Run it locally

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Then open http://localhost:8000/docs for the interactive API playground.

## Deploy

Deployed on Fly.io (`fly deploy` from `backend/`). The leaderboard database
lives on a Fly volume. The app is offline-first and degrades gracefully if
the backend is unreachable.
