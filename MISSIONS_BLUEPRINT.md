# Ghar Missions Blueprint — v1

**Date:** 2026-09-27
**Status:** Bet chosen. Build not started.
**Decision:** Missions first. Som fills the 9 silent word clips; then we build.

## 0. Where we stand

- Backend runs on Som's Mac. Pack `nepal-v1`: 3 decks, 13 words, 1 Tihar quest.
- Audio: 3 words in Som's voice (pani, selroti, khana), momo = placeholder chime, **9 words silent**.
- iOS app runs in the simulator, streams audio from the backend.
- Competition research done: O Nepali has content parity (alphabet, animals, conversations,
  festivals) and decent lessons. We do **not** win on word lists.
- The bet: we win on what the kid **does** — real-world missions no competitor has.

## 1. The bet we're testing

**Thesis:** A kid who *does* something in Nepali (says a greeting to grandma, sings a
Deusi line for the family) learns deeper and comes back more than a kid who only
taps flashcards.

**How we know if we're right (cousin test, 2 weeks after he gets the build):**
- He completes at least 5 missions.
- He does at least 1 mission **without anyone asking him to**.
- He tells Som about one mission in his own words.

If zero unprompted missions happen, the thesis is wrong and we ask him why —
that's data, not failure.

## 2. What a mission is

A mission is a tiny real-world quest: one instruction, one action in Nepali,
done **with a real person**, not inside the app. The app gives the instruction
(with audio), the world is where it happens.

Anatomy of a mission (every mission has all of these):
- **id** — short label, e.g. `tihar-greeting`
- **title** — English + Nepali, e.g. "Tihar Greeting" / "तिहारको शुभकामना"
- **prompt** — the actual instruction, English + Nepali, e.g.
  "Say 'Shuva Tihar!' to someone you love." / "शुभ तिहार!"
- **audio** — family-recorded clip reading the prompt (so a 5-year-old who can't
  read yet can still do missions)
- **festival** (optional) — groups seasonal missions, e.g. `tihar`
- **age_band** — default `"all"`; later missions can target seedling/explorer/rooted
- **xp** — points for finishing, default 10

### The 5 seed missions (v1)

1. **tihar-greeting** — "Say 'Shuva Tihar!' (शुभ तिहार) to someone you love." (festival: tihar)
2. **count-to-five** — "Count to 5 in Nepali — ek, dui, tin, char, paanch — for a family member."
3. **dinner-words** — "At dinner, point to 3 foods and say their Nepali names."
   (Ties straight into the Food deck: momo, pani, selroti, khana.)
4. **deusi-line** — "Learn one Deusi/Bhailo line and sing it for your family." (festival: tihar)
5. **tihar-smell** — "Ask your grandparents: what did Tihar smell like when you were little?"

## 3. How completing a mission works (v1 — deliberately simple)

1. Kid opens the Missions tab, taps a mission.
2. Sees the prompt (English + Nepali) and a speaker button that plays the
   instruction clip — same speaker-button pattern as the word cards.
3. Goes and does it in the real world.
4. Comes back, taps the big **"I did it! +10 XP"** button.
5. The mission gets a checkmark. XP total goes up. Streak logic: if they finish
   at least one mission today and yesterday too, the streak grows.

**Everything about progress lives on the phone.** No accounts, no login, no
photos, no uploads, nothing sent anywhere. That's not just simpler to build —
it's the COPPA-safe design: for under-13s, the safest data is data that never
leaves the device. And the missions *require* a family member in the real world,
so parental involvement isn't a compliance checkbox, it's the game mechanic.

**Explicitly NOT in v1:** photo/video proof of missions, leaderboards, sharing
missions with friends, server-side progress, push notification reminders.
Any of those can come later; none of them test the thesis.

## 4. Backend changes

Two files change. `main.py` does **not** change — here's why that's the payoff
of the pack architecture: `/packs/{pack_id}` already returns the whole pack as
JSON, so missions ride along inside the pack for free. No new endpoints.

### 4a. `backend/app/schemas.py` — add the Mission model

```python
class Mission(BaseModel):
    id: str                       # e.g. "tihar-greeting"
    title_en: str                 # "Tihar Greeting"
    title_ne: str                 # "तिहारको शुभकामना"
    prompt_en: str                # "Say 'Shuva Tihar!' to someone you love."
    prompt_ne: str                # "शुभ तिहार!"
    audio_url: str                # "/audio/nepal-v1/tihar-greeting.m4a"
    festival: str | None = None   # "tihar" — groups seasonal missions
    age_band: str = "all"         # "all" | "seedling" | "explorer" | "rooted"
    xp: int = 10
```

And one line added to `ContentPack`:

```python
class ContentPack(BaseModel):
    ...
    decks: list[Deck]
    quests: list[Quest]
    missions: list[Mission] = []   # <-- new; default [] keeps old packs valid
```

Why `= []` matters (teaching point): the default means a pack *without* missions
still passes validation. That's backwards compatibility — old data keeps working
when the shape grows. Same trick as `image: str | None = None` on Word.

Note: `Quest` already has a `mission: str` field (one real-world mission per
quest, e.g. the Tihar quest's "Say 'Shuva Tihar' to someone you love"). That
string was the seed of this whole idea. It stays as-is; full missions now live
in the top-level `missions` list where they can have audio, XP, and checkmarks.

### 4b. `backend/app/data/nepal-v1.json` — add the 5 seed missions

A new top-level key next to `decks` and `quests`:

```json
"missions": [
    {
        "id": "tihar-greeting",
        "title_en": "Tihar Greeting",
        "title_ne": "तिहारको शुभकामना",
        "prompt_en": "Say 'Shuva Tihar!' to someone you love.",
        "prompt_ne": "शुभ तिहार!",
        "audio_url": "/audio/nepal-v1/tihar-greeting.m4a",
        "festival": "tihar",
        "age_band": "all",
        "xp": 10
    }
]
```

Same nesting rules Som already learned the hard way: each mission object goes
**inside** the `missions` array, commas between objects, filenames must match
`audio_url` exactly.

## 5. iOS changes

### 5a. `Models.swift` — mirror the Mission struct

Same mirror rule as every other model: Python `snake_case` becomes Swift
`camelCase`, and `.convertFromSnakeCase` in GharAPI.swift does it automatically.

```swift
struct Mission: Codable, Identifiable {
    let id: String
    let titleEn: String
    let titleNe: String
    let promptEn: String
    let promptNe: String
    let audioUrl: String
    let festival: String?
    let ageBand: String
    let xp: Int
}
```

And one line in `ContentPack`:

```swift
struct ContentPack: Codable {
    ...
    let decks: [Deck]
    let quests: [Quest]
    let missions: [Mission]
}
```

### 5b. `ContentView.swift` — a Missions tab

Today the app is one `NavigationStack` showing decks. Missions are a peer of
lessons, not a subsection, so the app grows a `TabView` with two tabs:
"Lessons" (what exists now) and "Missions" (new). Roughly five lines to add
the tab; the existing list code moves under the Lessons tab untouched.

### 5c. New views — `MissionsView` + `MissionDetailView`

- **MissionsView:** list of missions from `pack.missions`. Each row: title
  (English + Nepali), XP badge, checkmark if done. Tapping pushes the detail.
- **MissionDetailView:** the prompt big on screen (EN + NE), speaker button
  streaming the instruction clip — the *exact* AVPlayer pattern already in
  `DeckView.play(word:)`, just pointed at `mission.audioUrl` — and the
  "I did it! +XP" button.

### 5d. Progress storage — `@AppStorage`

Three tiny values, all on-device:
- `doneMissions` (String): completed mission ids, comma-separated, e.g.
  `"tihar-greeting,dinner-words"`. `@AppStorage` only holds simple types, so a
  flat string beats a fancy structure for v1.
- `xpTotal` (Int): running XP total.
- `lastMissionDay` (String) + `streak` (Int): store today's date as
  `"2026-09-27"` when a mission is completed; if yesterday's date is stored
  when a new one completes, streak grows, otherwise it resets to 1.

Teaching point for later: `@AppStorage` is a SwiftUI wrapper around
`UserDefaults` — the phone's tiny key-value drawer. Same drawer, prettier key.

## 6. Build order — who does what

| # | Step | Who | Notes |
|---|------|-----|-------|
| 1 | Record 9 silent word clips + 5 mission instruction clips (14 total) | Som | Same workflow he knows: QuickTime/Voice Memos → `mv` into `backend/app/static/audio/nepal-v1/` with the exact `audio_url` filename. Mission clips read the **prompt** (both languages is nice, Nepali-only is fine). |
| 2 | Add `Mission` + `ContentPack.missions` to `schemas.py` | Me (Som watches) | Teaching: schema-first — the contract grows before the data. |
| 3 | Add the 5 seed missions to `nepal-v1.json`, validate, commit | Me (Som watches) | Teaching: validate after every content edit (`python -c` JSON check like before). |
| 4 | Som opens `/docs`, GETs `/packs/nepal-v1`, finds `"missions"` | Som | The playground loop again — he sees his content flowing before any app code exists. |
| 5 | Add `Mission` struct + `ContentPack.missions` to `Models.swift` | Me (Som watches) | Teaching: the mirror rule, snake→camel. |
| 6 | `ContentView` grows a `TabView` (Lessons \| Missions) | Me (Som watches) | Teaching: TabView in ~5 lines; existing code moves untouched. |
| 7 | Build `MissionsView` + `MissionDetailView` | Me (Som watches) | Teaching: NavigationLink again, and the AVPlayer pattern reused — patterns compound. |
| 8 | Completion + XP + streak via `@AppStorage` | Me (Som watches) | Teaching: UserDefaults drawer, why on-device = COPPA-safe. |
| 9 | Som runs in simulator: opens Missions, plays a clip, taps "I did it", watches XP move | Som | End-to-end with his own voice on the clips. |
| 10 | TestFlight → cousin | Together | See §7. |
| 11 | Cousin test week → notes → iterate | Som + cousin, me on standby | Measure against §1 success criteria. |

Steps 2–8 are one sitting each, in order — backend contract, then content, then
app. Never app-before-contract: that's how shape mismatches are born.

## 7. TestFlight beta (cousin = tester #1)

1. Som enrolls in the **Apple Developer Program** ($99/year — real cost, no way
   around it for TestFlight).
2. In Xcode: Product → Archive → Distribute → App Store Connect.
3. In App Store Connect: add the build to TestFlight, invite cousin by email.
4. Cousin installs the TestFlight app on his phone. No backend needed on his
   end for v1 *if* the app still points at Som's Mac — **decision needed**:
   for the cousin test, the backend must be reachable from his phone, which
   means either Som's Mac on the same Wi-Fi with the Mac's LAN IP in
   `GharAPI.baseURLString`, or the backend deployed somewhere (cheapest real
   option: a tiny cloud VM or Render/Railway free tier — and that's a legit
   DevOps portfolio story: "deployed the API my app talks to").
5. Give him zero instructions beyond "try the missions." Watch what he does
   unprompted — that's the data.

## 8. Scope guardrails — not in v1, no matter how tempting

- Photo/video proof of missions (COPPA + moderation burden)
- Accounts, login, leaderboards, friend features
- Server-side progress sync
- Push notification reminders
- Teen (Rooted) content — that's the *next* bet, not this one
- Country #2 — the pack system is ready for it; content isn't

If an idea isn't needed to test the §1 thesis, it waits.

## 9. After missions

1. **Retention deepening** — whatever the cousin week teaches us. Streak rewards,
   weekly festival missions, harder missions that unlock.
2. **Teen mode (Rooted 14–20)** — the bet after this one. Older kids get
   conversation missions, slang, festival hosting (e.g. "run Deusi/Bhailo for
   your block").
3. **Country #2** — one new JSON file + audio folder. The architecture was built
   for this day; no code changes.

---
*Companion docs: `PRODUCT_SPEC.md` (what Ghar is), `WIREFRAMES.md` (screens),
`competition-landscape` page (why missions — the O Nepali head-to-head).*
