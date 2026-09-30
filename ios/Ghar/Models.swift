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
}

struct Deck: Codable, Identifiable {
    let id: String
    let title: String
    let theme: String
    let minAgeBand: String      // "seedling" | "explorer" | "rooted"
    let words: [Word]
}

struct QuestScene: Codable, Identifiable {
    let id: String
    let textNpRomanized: String
    let textEn: String
    let audioUrl: String
    let choicePrompt: String?
    let choices: [String]
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
}
