#!/bin/bash
# Downloads the 4 dialogue character portraits into the asset catalog.
# Safe to re-run.
set -e
BASE="$HOME/Desktop/Ghar/ios/Assets.xcassets"
curl -sSL -o "$BASE/older-neutral.imageset/older-neutral.png" "https://muse.ai/files/1264993353369034/1846558356712142/y9xccjctv3zxu2xe658m2l6y/older_neutral.png"
curl -sSL -o "$BASE/older-talking.imageset/older-talking.png" "https://muse.ai/files/1264993353369034/1079244868194802/bi5ay3skv27k7znjt85kaszg/older_talking.png"
curl -sSL -o "$BASE/younger-neutral.imageset/younger-neutral.png" "https://muse.ai/files/1264993353369034/1454556293213570/kp7u66kilp7j4bqbz66gk6ka/younger_neutral.png"
curl -sSL -o "$BASE/younger-talking.imageset/younger-talking.png" "https://muse.ai/files/1264993353369034/1405186844465957/nx6n2xqc3mwrv43i3nmslt7b/younger_talking.png"
echo "downloaded:"
ls -la "$BASE"/*.imageset/*.png
