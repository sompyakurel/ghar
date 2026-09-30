#!/usr/bin/env python3
"""Merge vowels+consonants into one Alphabets deck with sections,
and append the Animals deck with real photo URLs.

Usage: merge_decks.py <input.json> <output.json>
Output format: indent=2, literal Devanagari (Som's hand-edit style).
"""
import json
import sys

SRC = sys.argv[1]
DST = sys.argv[2]

with open(SRC, encoding="utf-8") as f:
    pack = json.load(f)

# --- 1. Merge vowels + consonants into one Alphabets deck ---
vowels = next(d for d in pack["decks"] if d["id"] == "vowels")
consonants = next(d for d in pack["decks"] if d["id"] == "consonants")

VOWEL_SECTION = "Vowels (स्वर)"
CONSONANT_SECTION = "Consonants (व्यञ्जन)"

for w in vowels["words"]:
    w["section"] = VOWEL_SECTION
for w in consonants["words"]:
    w["section"] = CONSONANT_SECTION

alphabet_deck = {
    "id": "alphabet",
    "title": "Alphabets",
    "theme": "alphabet",
    "min_age_band": "seedling",
    "words": vowels["words"] + consonants["words"],
}

# --- 2. Animals deck: real photos, Nepali words, Som records the audio ---
ANIMALS = [
    # (id, devanagari, romanized, english, example_np, example_en)
    ("kukur",   "कुकुर", "kukur",   "dog",      "Kukur bhukchha.",            "The dog barks."),
    ("biralo",  "बिरालो", "biralo",  "cat",      "Biralo doodh piuchha.",       "The cat drinks milk."),
    ("gaai",    "गाई",  "gaai",    "cow",      "Gaai ghaans khaanchha.",      "The cow eats grass."),
    ("bagh",    "बाघ",  "bagh",    "tiger",    "Bagh jangal ma baschha.",     "The tiger lives in the jungle."),
    ("haatti",  "हात्ती", "haatti",  "elephant", "Haatti thulo chha.",          "The elephant is big."),
    ("baandar", "बाँदर", "baandar", "monkey",   "Baandar rukh ma chadhchha.",  "The monkey climbs the tree."),
    ("chara",   "चरा",  "chara",   "bird",     "Chara aakaash ma udchha.",    "The bird flies in the sky."),
    ("maachha", "माछा", "maachha", "fish",     "Maachha paani ma paudinchha.", "The fish swims in the water."),
    ("ghoda",   "घोडा", "ghoda",   "horse",    "Ghoda daudinchha.",           "The horse runs."),
    ("bakhra",  "बाख्रा", "bakhra",  "goat",     "Bakhra ghaans khaanchha.",     "The goat eats grass."),
    ("bhainsi", "भैँसी", "bhainsi", "buffalo",  "Bhainsi kheth ma kaam garchha.", "The buffalo works in the field."),
    ("kharayo", "खरायो", "kharayo", "rabbit",   "Kharayo chaadai daudinchha.", "The rabbit runs fast."),
]

animal_words = [
    {
        "id": aid,
        "devanagari": dev,
        "romanized": rom,
        "english": eng,
        "audio_url": f"/audio/nepal-v1/anim_{aid}_np.m4a",
        "has_audio": False,
        "image": f"/images/nepal-v1/anim_{aid}.jpg",
        "example_sentence_np": ex_np,
        "example_sentence_en": ex_en,
    }
    for (aid, dev, rom, eng, ex_np, ex_en) in ANIMALS
]

animals_deck = {
    "id": "animals",
    "title": "Animals",
    "theme": "animals",
    "min_age_band": "seedling",
    "words": animal_words,
}

# --- 3. Rebuild deck list: alphabet first, then the rest, animals at the end ---
rest = [d for d in pack["decks"] if d["id"] not in ("vowels", "consonants")]
pack["decks"] = [alphabet_deck] + rest + [animals_deck]

with open(DST, "w", encoding="utf-8") as f:
    json.dump(pack, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"decks: {[d['id'] for d in pack['decks']]}")
print(f"alphabet words: {len(alphabet_deck['words'])}, animals: {len(animal_words)}")
