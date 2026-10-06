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
    has_audio: bool = True      # False while the family still needs to record it;
                                # the app keeps these out of the listening quiz until then
    image: str | None = None     # optional illustration asset name
    section: str | None = None   # optional subsection header inside a deck,
                                 # e.g. "Vowels (स्वर)" inside Alphabets;
                                 # the app groups words by this, in file order
    example_sentence_np: str | None = None   # Romanized Nepali, e.g. "Mitho chha!"
    example_sentence_en: str | None = None   # "It's delicious!"
    quiz_hint: str | None = None             # short English hint shown under the
                                             # picture in the picture quiz,
                                             # e.g. "A brass pot with mango leaves"
    breakdown: str | None = None   # word-by-word gloss for phrases,
                                   # e.g. "तपाईंको (your) + नाम (name)...";
                                   # the app shows it on the teaching card
    speaker: str | None = None   # "A" or "B" — which person says this line
                                 # in the Daily Conversations dialogues;
                                 # the app shows an A/B badge in the list
    color_hex: str | None = None   # e.g. "#E53935" — Colors deck swatch;
                                   # the app paints the color chip from this


class FestivalPhrase(BaseModel):
    devanagari: str                  # दशैंको शुभकामना!
    romanized: str                   # "dashainko shubhakamana!"
    english: str                     # "Happy Dashain!"
    audio_url: str | None = None     # "/audio/nepal-v1/dash_phrase_shubhakamana_np.m4a"
    has_audio: bool = False          # flipped true once Som records the phrase


class Deck(BaseModel):
    id: str                      # e.g. "food"
    title: str                   # "Food"
    theme: str                   # used for card art
    cover_image: str | None = None  # optional deck cover art,
                                    # e.g. "/images/nepal-v1/cover_food.jpg";
                                    # the app shows it next to the deck title
    kind: str = "words"             # "words" = plain word list;
                                    # "festival" = animated festival experience
                                    # (Dashain, Tihar); "convo" = animated
                                    # conversation scene + practice game.
                                    # The app picks the screen by this value.
    min_age_band: str = Field(
        default="seedling",
        description="seedling (5-8) | explorer (9-13) | rooted (14-20)",
    )
    phrases: list[FestivalPhrase] | None = None  # optional "say it" strip (Dashain)
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
    verified_xp: int = 25        # grown-up-confirmed payout


class ContentPack(BaseModel):
    """One country's full content. Nepal = nepal-v1. Adding a new country
    later = a new JSON file + new audio. No code changes, no app update."""
    id: str                      # e.g. "nepal-v1"
    version: str                 # "1.0.0"
    country: str                 # "Nepal"
    language: str                # "Nepali"
    decks: list[Deck]
    quests: list[Quest]
    missions: list[Mission] = []  # default [] keeps packs without missions valid
    praise: list[Word] = []       # Nepali praise words (syabas, ramro, badhai);
                                  # WinFanfare plays one at random (Som's
                                  # recording) for every win EXCEPT the
                                  # Dashain/Tihar picture quizzes, which
                                  # stay silent apart from the tapped word
    myghar_audio: dict[str, bool] = {}  # My Ghar decoration/scene names;
                                  # id -> has_audio. The app plays
                                  # /audio/nepal-v1/myghar_<id>_np.m4a when
                                  # true, else the phone's TTS voice.
