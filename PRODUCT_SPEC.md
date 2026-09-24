# Ghar — Product Spec v0.1 (iOS MVP)

**Working title:** Ghar (घर = home). Test alternatives: Mero Roots, Thalo.
**One-liner:** An iOS app that helps diaspora kids (ages 5–20) speak their heritage language and live their culture — starting with Nepali, built to expand to any country.

## The problem
US-born diaspora kids want to learn their native language and culture, but existing tools are either tourist phrasebooks or kids' flashcard apps with no identity hook. Nothing makes being Nepali feel cool, social, and theirs.

## Age bands (one app, three modes)
| Band | Name | UX principle |
|------|------|--------------|
| 5–8 | Seedling | Co-play with a parent. Big tap targets, everything read aloud, no reading required. |
| 9–13 | Explorer | Independent play. Games, quizzes, map adventures. COPPA: family-only circles, no public profiles. |
| 14–20 | Rooted | Identity-driven. Slang, AI conversation buddy, remixable video, streaks. |

The account grows with the kid; modes unlock by age. Parent sets the band for under-13s.

## Personas
- **Aarav, 6.** Understands "khana khau" but answers in English. Uses the app on mom's iPad after dinner, mom taps along.
- **Priya, 11.** Can follow family conversations, can't read Devanagari. Wants to beat her brother's XP and unlock Pokhara on the map.
- **Cousin, 17** (Som's real-world muse). Wants to hold a real conversation with grandparents and get the jokes at Dashain. Needs low-shame private practice before performing for family.

## MVP v1.0 — iOS feature list
1. **Onboarding** — pick age band (parent confirms for <13), pick "where my family is from" (region of Nepal), choose avatar.
2. **Learn tab**
   - Devanagari tracing: finger-trace क ख ग with stroke guidance + family-recorded audio per letter.
   - Themed vocab decks (100 words v1): Family, Food, Festivals, Home. Each card: Devanagari + Romanized + audio + picture.
   - Listen-and-repeat with pronunciation scoring (iOS Speech framework).
   - Spaced repetition: words resurface right before you'd forget them.
3. **Quests tab** (culture)
   - v1 quests: Dashain (tika blessing script), Tihar (song + meaning per day), Momo Challenge (order at a shop roleplay), Map Trek (unlock regions of Nepal as you earn XP).
   - Each quest = 3–5 min interactive story with choices, audio, and a "try it on family" mission.
4. **Family Circle** (COPPA-safe social)
   - Invite-only: family members join by code. Grandma records a voice challenge ("say this blessing"), kid replies with audio, family reacts.
   - No public profiles, no discoverability for under-13 bands.
5. **Progress** — XP, streaks, Nepal map that fills in, avatar accessories (earn the dhaka topi).
6. **AI Buddy** (14–20 band, v1.0 if time allows else v1.1) — voice chat tutor that code-switches to English when stuck. Roleplays: ordering momo, introducing yourself to relatives.

**Explicitly NOT in v1:** public video feed/duets, Android, offline mode, non-Nepali languages.

## Content plan — family-recorded audio
Som's family records everything for v1. Recording guide:
- iPhone Voice Memos, quiet room, 6 inches from mouth, one phrase per file.
- Naming: `{deck}_{word}_np.m4a` (e.g. `food_momo_np.m4a`).
- v1 shopping list: 36 alphabet sounds, 100 vocab words, 12 quest narrations, 5 songs/rhymes, 20 "grandma challenges."
- Each clip reviewed by one fluent elder for pronunciation before shipping.

## Tech architecture (fits Som's Python/DevOps learning track)
- **iOS:** SwiftUI, native. Best tracing/audio performance, simplest App Store path. (Alternative: React Native if Android becomes urgent — not recommended for v1.)
- **Backend:** Python FastAPI + PostgreSQL. Content served as versioned JSON "content packs" — this is the expansion mechanism: Nepal pack v1, future countries = new packs, no app rewrite.
- **Audio:** stored in S3-compatible object storage, streamed/cached on device.
- **AI Buddy:** speech-to-text + LLM with a Nepali-tutor system prompt, TTS back. Start with one provider, abstract behind an interface.
- **DevOps:** GitHub repo, GitHub Actions CI (lint/test/build), TestFlight for family beta, backend on a small cloud VM or serverless. This doubles as Som's portfolio project.
- **Analytics (privacy-first):** on-device streak/XP; server only sees anonymized lesson-completion events. No ads SDKs, no third-party trackers — required for a kids' app.

## COPPA / privacy notes (under-13)
- No account required to try; parent creates the family circle.
- No public profiles, no chat with strangers, no behavioral ads — ever.
- Voice recordings stay inside the family circle.

## Success metrics for the family beta
- 5+ day streak in first 2 weeks (any band).
- Kid uses 3+ Nepali phrases unprompted with family (ask parents weekly).
- Quest completion rate > 60%.

## Open questions
- Builder: Som builds it himself (slower, learning) vs. scaffolded prototype (faster)?
- TestFlight family beta list: who are the first 5–10 testers?
- Elder reviewer: which fluent family member signs off on pronunciation?
