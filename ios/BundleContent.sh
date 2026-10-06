#!/bin/bash
# BundleContent.sh — bundles the Ghar content pack into the app at build time.
# Runs as an Xcode build-phase script (see project.pbxproj, "Bundle Content").
#
# Source of truth stays in ../backend:
#   backend/app/data/nepal-v1.json          -> Content/packs/nepal-v1.json
#   backend/app/static/audio/nepal-v1/*.m4a -> Content/audio/nepal-v1/
#   backend/app/static/images_b64/*.jpg.b64 -> Content/images/nepal-v1/ (decoded)
#
# The bundle mirrors the backend's URL layout, so the app's existing
# `GharAPI.baseURLString + "/audio/…"` code works unchanged — the base URL
# just becomes a file:// URL into this folder instead of http://localhost:8000.
#
# Workflow: add recordings/images (or edit the JSON) in ../backend, then
# rebuild (Cmd+R). New clips also need their has_audio flag flipped in the JSON.
set -euo pipefail

BACKEND="$PROJECT_DIR/../backend"
DST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Content"

mkdir -p "$DST/packs" "$DST/audio/nepal-v1" "$DST/images/nepal-v1"

# The content pack itself. No .json extension: the app requests /packs/nepal-v1,
# mirroring the backend URL, so the file on disk must match exactly.
cp "$BACKEND/app/data/nepal-v1.json" "$DST/packs/nepal-v1"

# Spoken clips: copied as-is.
cp "$BACKEND"/app/static/audio/nepal-v1/*.m4a "$DST/audio/nepal-v1/"

# Pictures: stored base64 in the backend, decoded to real JPEGs here.
# Python does the decode (deterministic; macOS base64 chokes on some valid
# files). A file that still fails is skipped with a warning, not a build error.
for f in "$BACKEND"/app/static/images_b64/*.b64; do
    out="$DST/images/nepal-v1/$(basename "$f" .b64)"
    if python3 -c 'import base64,sys; open(sys.argv[2],"wb").write(base64.b64decode(b"".join(open(sys.argv[1],"rb").read().split())))' "$f" "$out" 2>/dev/null; then
        :
    else
        echo "WARNING: skipping corrupt image $f" >&2
        rm -f "$out"
    fi
done

echo "Ghar content bundled: $(ls "$DST/audio/nepal-v1" | wc -l | tr -d ' ') clips, $(ls "$DST/images/nepal-v1" | wc -l | tr -d ' ') images."
