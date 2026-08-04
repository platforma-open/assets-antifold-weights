#!/usr/bin/env bash
#
# Download the AntiFold model checkpoint into the variant's indexed_model/ directory.
#
# Usage:
#   download-weights.sh <modelInfo.json>
#
# modelInfo.json schema:
#   {
#     "base_url": "https://opig.stats.ox.ac.uk/data/downloads/AntiFold/models",
#     "target_dir": "antifold",
#     "files": ["model.pt"],
#     "url_suffix": "",                              // optional; default "?download=1"
#     "expected_bytes": { "model.pt": 566838063 }    // required, one entry per file
#   }
#
# Each file is fetched from "<base_url>/<file><url_suffix>". `url_suffix` defaults to
# "?download=1", which is a Zenodo convention; a direct path such as the OPIG one must
# set it to "" or the request 404s.
#
# `expected_bytes` is not a sanity check, it is the contract. The consumer must never
# reach the network at run time, and AntiFold re-downloads the checkpoint whenever the
# file it finds is unusable. So a short or wrong file must fail this build rather than
# ship an asset whose consumer silently falls back to a 540.6 MiB runtime fetch.
#
# The asset's package.json must declare `block-software.entrypoints.main.asset.root`
# pointing at `./indexed_model/<target_dir>` — pl-pkg picks up the downloaded
# files from there.

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <modelInfo.json>" >&2
    exit 1
fi

MODEL_INFO="$1"

if [ ! -f "$MODEL_INFO" ]; then
    echo "Error: $MODEL_INFO not found" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required (install via 'brew install jq' or 'apt-get install jq')" >&2
    exit 1
fi

# BSD stat and GNU stat spell "size in bytes" differently; try GNU, fall back to BSD.
# Callers must check the file exists first — on a missing path both forms fail, and
# under `set -e` that would abort the script instead of reporting "absent".
file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1"
}

BASE_URL=$(jq -r '.base_url' "$MODEL_INFO")
TARGET_DIR=$(jq -r '.target_dir' "$MODEL_INFO")
URL_SUFFIX=$(jq -r '.url_suffix // "?download=1"' "$MODEL_INFO")

if [ -z "$BASE_URL" ] || [ "$BASE_URL" = "null" ]; then
    echo "Error: base_url missing from $MODEL_INFO" >&2
    exit 1
fi
if [ -z "$TARGET_DIR" ] || [ "$TARGET_DIR" = "null" ]; then
    echo "Error: target_dir missing from $MODEL_INFO" >&2
    exit 1
fi

OUTPUT_DIR="indexed_model/$TARGET_DIR"
mkdir -p "$OUTPUT_DIR"

mapfile -t FILES < <(jq -r '.files[]' "$MODEL_INFO")
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "Error: no files listed in $MODEL_INFO" >&2
    exit 1
fi

for file in "${FILES[@]}"; do
    url="${BASE_URL}/${file}${URL_SUFFIX}"
    out="$OUTPUT_DIR/$file"
    tmp="$out.part"

    want=$(jq -r --arg f "$file" '.expected_bytes[$f] // "null"' "$MODEL_INFO")
    # A file with no declared size cannot be checked at all. Fail naming it, or every
    # build re-downloads and then fails the comparison, which reads like a mystery loop.
    if [ "$want" = "null" ] || [ -z "$want" ]; then
        echo "Error: no expected_bytes entry for $file in $MODEL_INFO" >&2
        exit 1
    fi

    # A present file is trusted only if its size is right. Skipping on non-empty alone
    # lets a curl that died mid-transfer leave a partial file that every later build
    # reuses while reporting success. `[ -f ]` first: a missing file must read as
    # absent, and a bare stat on a missing path would abort under `set -e`.
    if [ -f "$out" ] && [ "$(file_size "$out")" = "$want" ]; then
        echo "Already present at expected size ($want bytes), skipping: $out"
        continue
    fi
    if [ -f "$out" ]; then
        echo "Present but wrong size ($(file_size "$out") bytes, expected $want), re-fetching: $out" >&2
        rm -f "$out"
    fi

    echo "Downloading $url -> $out ..."
    # Download to a temp path and rename only after the size check, so a partial file
    # can never occupy the final path in the first place.
    # -f: fail on HTTP errors; -L: follow redirects; --retry: ride out transient
    # upstream flakiness (the whole reason this asset exists).
    # One compound statement, not two: under `set -e` a bare failing curl exits the
    # script immediately, so a cleanup line written after it would never run.
    curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
        -o "$tmp" "$url" || { rm -f "$tmp"; echo "Error: download failed: $url" >&2; exit 1; }

    got=$(file_size "$tmp")
    if [ "$got" != "$want" ]; then
        rm -f "$tmp"
        echo "Error: $url returned $got bytes, expected $want — truncated download, or upstream changed the file" >&2
        exit 1
    fi
    mv "$tmp" "$out"
done

# Bundle the license notes alongside the weights so they ship inside the asset. This
# asset carries LICENSE-NOTES.md and no LICENSE: the weights license is unresolved and
# is not inherited from AntiFold's BSD 3-Clause code license.
NOTES_SRC="$(dirname "$MODEL_INFO")/LICENSE-NOTES.md"
if [ -f "$NOTES_SRC" ]; then
    cp "$NOTES_SRC" "$OUTPUT_DIR/LICENSE-NOTES.md"
    echo "Bundled license notes: $NOTES_SRC -> $OUTPUT_DIR/LICENSE-NOTES.md"
else
    echo "WARNING: no LICENSE-NOTES.md at $NOTES_SRC; asset will ship without license notes." >&2
fi

echo "Done. Files in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"
