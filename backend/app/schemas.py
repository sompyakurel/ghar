"""
Data shapes for Ghar content packs.

Teaching notes for Som:
- Pydantic BaseModel = a Python class that validates data on the way in.
  If a JSON file is missing a field or has the wrong type, the API
  raises a clear error instead of sending broken content to the app.
- `str | None = None` means "optional string" — the field can be missing.
- These models are the CONTRACT between backend and iOS app. The Swift
  structs in the app will mirror these field-for-field.
"""
from pydantic import BaseModel, Field


class Word(BaseModel):
    id: str                      # e.g. "momo"
    devanagari: str              # मोमो
    romanized: str               # "momo"
    english: str                 # "dumpling"
    audio_url: str               # "/audio/nepal-v1/food_momo_np.m4a"
    image: str | None = None     # optional illustration asset name
    example_sentence_np: str | None = None   # Romanized Nepali, e.g. "Mitho chha!"
    example_sentence_en: str | None = None   # "It's delicious!"


class Deck(BaseModel):
    id: str                      # e.g. "food"
    title: str                   # "Food"
    theme: str                   # used for card art
    min_age_band: str = Field(
        default="seedling",
        description="seedling (5-8) | explorer (9-13) | rooted (14-20)",
    )
    words: list[Word]


class QuestScene(BaseModel):
    id: str
    text_np_romanized: str       # story text in Romanized Nepali
    text_en: str                 # English translation
    audio_url: str               # family-recorded narration
    choice_prompt: str | None = None   # e.g. "Which light do we put out first?"
    choices: list[str] = []      # tap options for the kid


class Quest(BaseModel):
    id: str                      # e.g. "tihar"
    title: str
    description: str
    min_age_band: str
    scenes: list[QuestScene]
    mission: str                 # real-world mission, e.g. "Say 'Shuva Tihar' to someone you love"


class ContentPack(BaseModel):
    """One country's full content. Nepal = nepal-v1. Adding a new country
    later = a new JSON file + new audio. No code changes, no app update."""
    id: str                      # e.g. "nepal-v1"
    version: str                 # "1.0.0"
    country: str                 # "Nepal"
    language: str                # "Nepali"
    decks: list[Deck]
    quests: list[Quest]
