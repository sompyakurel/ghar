# Ghar: Learn Nepali

Nepali language and culture for diaspora kids and teens — hear every word
in a real human voice, play quizzes that feel like games, take on real-life
missions, build your own house, and raise a pet dog that grows with you.

Modes for ages 5–8 (Seedling), 9–13 (Explorer), and 14–20 (Rooted).
22 lesson decks, 342 words, songs, rhymes, quizzes, Balloon Pop, Bagh-Chal,
and family leaderboards via nickname + group code.

Free to start. One-time $7.99 unlock, no ads, no subscription, Family Sharing.

## Structure

- `ios/` — the SwiftUI app (iOS 17+). Content is bundled at build time by
  `ios/BundleContent.sh` from `backend/app`.
- `backend/` — FastAPI service: content packs, the leaderboard API, and the
  support / privacy / landing pages.

## Run it

Open `ios/Ghar.xcodeproj` in Xcode and run. To run the backend locally:

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

## Status

v1.0 (build 14) submitted to the App Store — awaiting review.

Copyright © 2026 Som Pyakurel. All rights reserved.
