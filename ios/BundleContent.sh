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

# Songs pack: same pattern (no .json extension, mirrors /packs/songs-v1).
# Adding a song later = one JSON entry in songs-v1.json + one .m4a in
# backend/app/static/audio/songs-v1/ with has_audio flipped true.
cp "$BACKEND/app/data/songs-v1.json" "$DST/packs/songs-v1"
mkdir -p "$DST/audio/songs-v1"
for f in "$BACKEND"/app/static/audio/songs-v1/*.m4a; do
    [ -e "$f" ] || continue
    cp "$f" "$DST/audio/songs-v1/"
done

# Rhymes pack: same pattern (no .json extension, mirrors /packs/rhymes-v1).
cp "$BACKEND/app/data/rhymes-v1.json" "$DST/packs/rhymes-v1"
mkdir -p "$DST/audio/rhymes-v1"
for f in "$BACKEND"/app/static/audio/rhymes-v1/*.m4a; do
    [ -e "$f" ] || continue
    cp "$f" "$DST/audio/rhymes-v1/"
done

# Song clips that arrived split (transport limit): reassemble
# songs-v1_<name>.m4a.b64.part-* -> decoded <name>.m4a in the songs audio dir.
python3 - "$BACKEND" "$DST" <<'PYEOF'
import base64, glob, os, sys
backend, dst = sys.argv[1], sys.argv[2]
outdir = os.path.join(dst, "audio", "songs-v1")
groups = {}
pat = os.path.join(backend, "app", "static", "audio_b64", "songs-v1_*.m4a.b64.part-*")
for p in glob.glob(pat):
    base = os.path.basename(p)
    name = base[len("songs-v1_"):].partition(".m4a.b64.part-")[0]
    groups.setdefault(name, []).append(p)
for name, parts in sorted(groups.items()):
    parts.sort()
    try:
        blob = b"".join(b"".join(open(p, "rb").read().split()) for p in parts)
        data = base64.b64decode(blob)
    except Exception as e:
        print(f"WARNING: skipping corrupt song parts for {name}: {e}", file=sys.stderr)
        continue
    open(os.path.join(outdir, name + ".m4a"), "wb").write(data)
    print(f"reassembled song {name}.m4a from {len(parts)} parts")
PYEOF

# Spoken clips: copied as-is.
cp "$BACKEND"/app/static/audio/nepal-v1/*.m4a "$DST/audio/nepal-v1/"

# Cloned-voice clips: the assistant can't push binaries to this Mac, so they
# arrive as base64 text in audio_b64/ and get decoded here — same pattern as
# the images_b64 pictures above. Decoded after the cp so the clone wins.
for f in "$BACKEND"/app/static/audio_b64/*.m4a.b64; do
    [ -e "$f" ] || continue
    out="$DST/audio/nepal-v1/$(basename "$f" .m4a.b64).m4a"
    if python3 -c 'import base64,sys; open(sys.argv[2],"wb").write(base64.b64decode(b"".join(open(sys.argv[1],"rb").read().split())))' "$f" "$out" 2>/dev/null; then
        :
    else
        echo "WARNING: skipping corrupt clip $f" >&2
        rm -f "$out"
    fi
done

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

# My Ghar room art: dog poses, decoration sprites, room background.
# Source: backend/app/static/images/myghar/*.png -> Content/images/myghar/
mkdir -p "$DST/images/myghar"
for f in "$BACKEND"/app/static/images/myghar/*.png; do
    [ -e "$f" ] || continue
    cp "$f" "$DST/images/myghar/"
done

echo "Ghar content bundled: $(ls "$DST/audio/nepal-v1" | wc -l | tr -d ' ') clips, $(ls "$DST/images/nepal-v1" | wc -l | tr -d ' ') images."
