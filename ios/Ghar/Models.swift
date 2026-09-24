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
}
