import Foundation

// These structs mirror the backend's Pydantic models field-for-field.
// Backend (Python):  audio_url, min_age_band, text_np_romanized
// App (Swift):       audioUrl,  minAgeBand,  textNpRomanized
// The translation happens automatically via .convertFromSnakeCase
// in GharAPI.swift — so the property names just need to match
// after converting snake_case -> camelCase.

struct Word: Codable, Identifiable {
    let id: String
    let devanagari: String      // मोमो
    let romanized: String       // "momo"
    let english: String         // "dumpling"
    let audioUrl: String        // "/audio/nepal-v1/food_momo_np.m4a"
    let hasAudio: Bool?        // nil = pack data from before this field existed; treat as true
    let section: String?       // e.g. "Vowels (स्वर)" — subsection header inside a deck
    let image: String?
    let exampleSentenceNp: String?
    let exampleSentenceEn: String?
    let breakdown: String?         // word-by-word gloss for phrases,
                                   // e.g. "तपाईंको (your) + नाम (name)"
    let speaker: String?           // "A" or "B" — Daily Conversations dialogue speaker
    let colorHex: String?            // "#E53935" — Colors deck paints the swatch from this
    let quizHint: String?            // short English hint shown under the picture
                                     // in the picture quiz, e.g. "A brass pot
                                     // with mango leaves" — distinguishes
                                     // similar-looking pictures
}

// A tappable festival phrase, e.g. Dashain's "Say it this Dashain" strip.
struct FestivalPhrase: Codable {
    let devanagari: String      // दशैंको शुभकामना!
    let romanized: String       // "dashainko shubhakamana!"
    let english: String         // "Happy Dashain!"
    let audioUrl: String?       // "/audio/nepal-v1/dash_phrase_shubhakamana_np.m4a"
    let hasAudio: Bool?         // nil = pack data from before this field existed
}

struct Deck: Codable, Identifiable {
    let id: String
    let title: String
    let theme: String
    let coverImage: String?      // optional deck cover art, e.g. "/images/nepal-v1/cover_food.jpg"
    let kind: String?            // nil = data from before this field existed; treat as "words".
                                // "festival" decks open the animated FestivalView instead of the word list.
    let minAgeBand: String      // "seedling" | "explorer" | "rooted"
    let phrases: [FestivalPhrase]?  // optional "say it" strip (Dashain)
    let words: [Word]
}

struct QuestScene: Codable, Identifiable {
    let id: String
    let textNpRomanized: String
    let textEn: String
    let audioUrl: String
    let choicePrompt: String?
    let choices: [String]?      // nil = scene data from before choices existed; treat as []
}

struct Quest: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let minAgeBand: String
    let scenes: [QuestScene]
    let mission: String
}

struct ContentPack: Codable {
    let id: String
    let version: String
    let country: String
    let language: String
    let decks: [Deck]
    let quests: [Quest]
    let missions: [Mission]
    let praise: [Word]?      // optional so packs cached before this
                             // field existed still decode; use ?? []
    let mygharAudio: [String: Bool]?  // My Ghar decoration/scene names:
                             // id -> has_audio; nil = pack from before
                             // this field existed
}

/// A real-world mission: something the kid DOES, not a word list.
/// Mirrors the backend's Mission model field-for-field — the same
/// .convertFromSnakeCase trick translates title_ne -> titleNe.
struct Mission: Codable, Identifiable {
    let id: String
    let titleEn: String       // "Tihar Greeting"
    let titleNe: String       // "तिहारको शुभकामना"
    let promptEn: String      // "Say 'Tihar ko subhakamana!'..."
    let promptNe: String      // "तिहारको शुभकामना!"
    let audioUrl: String      // "/audio/nepal-v1/tihar-greeting.m4a"
    let festival: String?     // "tihar", or nil when it's not tied to one
    let ageBand: String       // "all"
    let xp: Int               // 10
    let verifiedXp: Int        // grown-up-confirmed payout (25)
    let hasAudio: Bool         // true once the family records the spoken play instruction

    // Custom decoder: verifiedXp/hasAudio were added after v1, so old
    // packs won't send them. decodeIfPresent keeps those decoding
    // instead of the synthesized init silently using defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        titleEn = try c.decode(String.self, forKey: .titleEn)
        titleNe = try c.decode(String.self, forKey: .titleNe)
        promptEn = try c.decode(String.self, forKey: .promptEn)
        promptNe = try c.decode(String.self, forKey: .promptNe)
        audioUrl = try c.decode(String.self, forKey: .audioUrl)
        festival = try c.decodeIfPresent(String.self, forKey: .festival)
        ageBand = try c.decode(String.self, forKey: .ageBand)
        xp = try c.decode(Int.self, forKey: .xp)
        verifiedXp = try c.decodeIfPresent(Int.self, forKey: .verifiedXp) ?? 25
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
    }
}
