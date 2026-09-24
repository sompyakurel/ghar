# Ghar — Wireframes v0.1 (iOS)

Design language: warm, playful, Nepali-inspired. Crimson + deep blue (flag colors) as accents on a warm cream background. Big rounded cards, chunky type for kids' modes, cleaner type for the teen mode. Every screen has a speaker button — nothing is reading-only.

## Global navigation
- **Onboarding (first launch):** Welcome animation → "How old are you?" (three big cards: 5–8, 9–13, 14–20) → "Where is your family from?" (region picker: Kathmandu Valley, Pokhara, Terai, etc. — sets quest flavor) → Avatar picker (earn accessories later) → Parent gate (under-13: parent creates Family Circle with a 6-digit code).
- **Tab bar (per mode):** Home | Learn | Quests | Family. (Teen mode adds a center "Buddy" mic button for the AI chat.)

---

## MODE 1 — Seedling (ages 5–8, co-play with parent)

**Home**
- Greeting in Nepali + English: "Namaste, Aarav! ☀️" (audio auto-plays once)
- Three giant cards: "Learn Words" (with today's word preview), "Story Quest" (with progress ring), "Sing a Song"
- Streak flame at top, kept gentle — no pressure copy for little kids
- "Grown-ups" button (small, bottom): parent dashboard — time played, words learned, recording upload

**Learn → Word card**
- Full-screen picture (e.g. momo), huge Devanagari मोमो + Romanized "momo", auto-plays family audio
- Two buttons: 🔊 "Hear it" and 🎤 "Say it" (speech scoring with a forgiving star animation — 1 star for trying)
- Swipe for next word. Every 5th card is a tiny game: "Tap the momo!"

**Learn → Trace letters**
- Big क on screen with numbered stroke order, finger-tracing with a sparkle trail
- Correct stroke → letter "pops" and plays its sound; wrong direction → gentle wiggle, no error state
- 3 letters per session max — short sessions on purpose

**Quest → Story (e.g. "Tihar is coming")**
- 5 swipeable scenes, illustrated, narrated by family audio with highlighted word-by-word text
- Each scene ends with one tap-choice ("Which light do we put out first? 🪔")
- Final scene: "Mission for tonight" — e.g. "Say 'Shuva Tihar' to someone you love" with a record button; recording goes to Family Circle

**Song screen**
- Lyrics in Romanized Nepali, big play button, bouncing-ball word highlighting, family-recorded song
- "Sing with me" mode: app sings a line, kid repeats (karaoke scoring, always kind)

---

## MODE 2 — Explorer (ages 9–13, independent, COPPA-safe)

**Home**
- Top: streak + total XP + level ("Yeti Cub → Mountain Goat → …")
- Hero card: "Continue: Map Trek — you are 200 XP from Pokhara!"
- Grid: Daily Deck, Quest of the week, Family Challenge (new badge if grandma sent one)

**Learn → Deck list → Flash session**
- Decks: Family, Food, Festivals, Home, plus locked "Slang" (unlocks at 14–20 mode)
- Card: Devanagari + Romanized + audio + example sentence ("Mitho chha! — It's delicious!")
- Self-grade after reveal: "Got it / Almost / Missed" → drives spaced repetition
- Session end: XP summary + which words graduate to "known"

**Learn → Quiz game ("Bazaar Run")**
- Timed market game: hear a word, tap the right stall/item from 4 pictures
- Combo multiplier, silly sound effects, leaderboard = family members only

**Quests → Quest detail (e.g. "Dashain")**
- Chapters with a progress path on screen; each chapter: 60-sec read + 3-question check + one real-world mission
- Mission example: "Ask a parent what Dashain smelled like when they were your age. Record their answer."
- Completing all chapters unlocks the region on the Nepal map + a story from an elder (family audio)

**Map of Nepal**
- Stylized map; regions unlock as quests complete; each unlocked region shows a "did you know" card + dialect note
- Long-term hook: "7 regions to unlock"

**Family Circle**
- Invite-only feed (family code): voice challenges from relatives, kid's recordings, emoji reactions only (no text comments for under-13)
- "Challenge me" button: kid can request a new word/challenge from a relative

---

## MODE 3 — Rooted (ages 14–20, identity-driven)

**Home**
- "Your Nepali today": one phrase-a-day card with cultural context ("'Ke chha?' isn't just 'what's up' — here's when elders expect 'Hajur, sanchai'")
- Continue cards: deck progress, quest progress, Buddy streak

**Buddy (AI conversation, center tab)**
- Big mic button, voice-first. Scenario picker: "Order at a momo shop" / "Introduce yourself to relatives" / "Small talk with grandparents"
- Buddy speaks Nepali, drops to English when you're stuck (toggleable "Nepali-only" hard mode)
- After each session: transcript with corrections + 3 phrases to save to your deck

**Learn → Decks**
- Same engine as Explorer, plus "Slang & Real Talk" deck and "Get the joke" deck (explains the family-party jokes)
- Romanized-first display option (many heritage teens can't read Devanagari yet — no shame, it's a setting)

**Quests**
- Deeper, essay-style: "The 2015 earthquake and why your parents still talk about it," "What caste/ethnicity means and doesn't mean," "Nepali music from Dohori to hip-hop" — each with a reflection prompt, not a quiz
- "Make it yours": create a 30-sec video of yourself doing the quest mission (stays in Family Circle unless teen chooses to share wider — default private)

**Profile**
- Streak, XP, map progress, saved phrases, "words that stuck" (used unprompted with family — self-reported, celebrated big)

---

## Design notes for the build
- Audio is the core interaction, not an add-on: every word, letter, scene, and challenge ships with family-recorded audio.
- Haptics on success (iOS Taptic Engine) — small thing, big feel for kids.
- Offline-first for Learn content (audio cached); Family Circle needs connection.
- Accessibility: Dynamic Type support, VoiceOver labels on all cards — non-negotiable for a kids' app.
- What we are NOT designing in v1: public feeds, DMs with strangers, ads, in-app purchase screens (monetization comes after the family beta proves the loop).
