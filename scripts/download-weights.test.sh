#!/usr/bin/env bash
#
# Unit tests for download-weights.sh.
#
# Usage:
#   ./scripts/download-weights.test.sh
#
# Every case is served by a local python http.server over a small fixture, so the suite
# never fetches the real 540.6 MiB checkpoint. Keep it that way: a test that touches
# opig.stats.ox.ac.uk stops being a unit test.
#
# The server logs one line per request, so "was a second request made" is an assertion
# rather than an inference.

set -uo pipefail   # deliberately not -e: most cases run the script expecting it to fail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNDER_TEST="$SCRIPT_DIR/download-weights.sh"

if [ ! -x "$UNDER_TEST" ]; then
    echo "Error: $UNDER_TEST is missing or not executable" >&2
    exit 1
fi
for tool in jq python3 curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool is required" >&2; exit 1; }
done

TMPROOT=$(mktemp -d)
SERVE_DIR="$TMPROOT/served"
SRV_LOG="$TMPROOT/server.log"
SRV_PID=""
PORT=""
mkdir -p "$SERVE_DIR"

PASSED=0
FAILED=0
CURRENT=""

cleanup() {
    if [ -n "$SRV_PID" ]; then
        kill "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null
    fi
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

start_server() {
    : > "$SRV_LOG"
    local port
    for port in $(seq 18080 18140); do
        # -u: unbuffered, so a request line is in the log by the time we read it.
        ( cd "$SERVE_DIR" && exec python3 -u -m http.server "$port" --bind 127.0.0.1 ) \
            >>"$SRV_LOG" 2>&1 &
        SRV_PID=$!
        local i
        for i in $(seq 1 50); do
            if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
                PORT="$port"
                return 0
            fi
            kill -0 "$SRV_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null
        SRV_PID=""
    done
    echo "Error: could not start python http.server on any port in 18080-18140" >&2
    return 1
}

# --- assertions ---------------------------------------------------------------

start_case() {
    CURRENT="$1"
    WORK="$TMPROOT/case-$((PASSED + FAILED + 1))"
    mkdir -p "$WORK"
    rm -f "$SERVE_DIR"/*
    : > "$SRV_LOG"
}

pass() { PASSED=$((PASSED + 1)); echo "PASS: $CURRENT"; }
fail() {
    FAILED=$((FAILED + 1))
    echo "FAIL: $CURRENT"
    echo "      $1"
    [ -s "$WORK/stderr.log" ] && sed 's/^/      stderr: /' "$WORK/stderr.log"
    return 0
}

# Serve a file of exactly $2 bytes under name $1. BSD head rejects `-c 0`.
serve_bytes() {
    if [ "$2" -eq 0 ]; then
        : > "$SERVE_DIR/$1"
    else
        head -c "$2" /dev/zero | tr '\0' 'x' > "$SERVE_DIR/$1"
    fi
}

# Write $WORK/modelInfo.json. $1 = files json array, $2 = expected_bytes json object,
# $3 = url_suffix, $4 = optional literal base_url override ("OMIT" drops the field).
write_manifest() {
    local files="$1" expected="$2" suffix="$3" base="${4:-http://127.0.0.1:$PORT}"
    if [ "$base" = "OMIT" ]; then
        jq -n --argjson f "$files" --argjson e "$expected" --arg s "$suffix" \
            '{target_dir:"antifold", files:$f, url_suffix:$s, expected_bytes:$e}' \
            > "$WORK/modelInfo.json"
    else
        jq -n --arg b "$base" --argjson f "$files" --argjson e "$expected" --arg s "$suffix" \
            '{base_url:$b, target_dir:"antifold", files:$f, url_suffix:$s, expected_bytes:$e}' \
            > "$WORK/modelInfo.json"
    fi
}

run_under_test() {
    ( cd "$WORK" && "$UNDER_TEST" ./modelInfo.json ) \
        >"$WORK/stdout.log" 2>"$WORK/stderr.log"
    echo $?
}

# Count GET requests for a path, as logged by http.server. `grep -c` already prints 0
# on no match, so the fallback must assign rather than echo a second line.
get_count() {
    local n
    n=$(grep -c "\"GET $1 HTTP" "$SRV_LOG" 2>/dev/null) || n=0
    echo "$n"
}

start_server || exit 1
echo "Serving fixtures from $SERVE_DIR on http://127.0.0.1:$PORT"
echo

OUT_REL="indexed_model/antifold/model.pt"

# 1. url_suffix "" is honoured: the direct URL is requested verbatim, exactly once.
start_case 'url_suffix "" requests the served path with no suffix, exactly once'
serve_bytes model.pt 1024
write_manifest '["model.pt"]' '{"model.pt":1024}' ''
code=$(run_under_test)
if [ "$code" != 0 ]; then
    fail "expected exit 0, got $code"
elif [ "$(get_count /model.pt)" != 1 ]; then
    fail "expected exactly 1 GET /model.pt, log has: $(grep -c 'GET' "$SRV_LOG")"
elif grep -q 'download=1' "$SRV_LOG"; then
    fail "a Zenodo-style ?download=1 suffix reached the server"
else
    pass
fi

# 2. A served file whose length matches expected_bytes is accepted.
start_case 'served length == expected_bytes -> exit 0, file present in indexed_model/'
serve_bytes model.pt 2048
write_manifest '["model.pt"]' '{"model.pt":2048}' ''
code=$(run_under_test)
if [ "$code" != 0 ]; then
    fail "expected exit 0, got $code"
elif [ ! -f "$WORK/$OUT_REL" ]; then
    fail "$OUT_REL missing"
elif [ "$(stat -c%s "$WORK/$OUT_REL" 2>/dev/null || stat -f%z "$WORK/$OUT_REL")" != 2048 ]; then
    fail "$OUT_REL has the wrong size"
else
    pass
fi

# 3. One byte short must fail the build, not ship a truncated checkpoint.
start_case 'served length one byte short of expected_bytes -> non-zero exit'
serve_bytes model.pt 1023
write_manifest '["model.pt"]' '{"model.pt":1024}' ''
code=$(run_under_test)
if [ "$code" = 0 ]; then
    fail "expected non-zero exit"
elif ! grep -q '1023 bytes, expected 1024' "$WORK/stderr.log"; then
    fail "error message does not report the byte counts"
else
    pass
fi

# 4. A zero-byte response is the degenerate short download.
start_case 'served zero-byte file -> non-zero exit'
serve_bytes model.pt 0
write_manifest '["model.pt"]' '{"model.pt":1024}' ''
code=$(run_under_test)
[ "$code" != 0 ] && pass || fail "expected non-zero exit"

# 5. curl -f turns an HTTP error into a build failure.
start_case '404 from the server -> non-zero exit (curl -f)'
write_manifest '["model.pt"]' '{"model.pt":1024}' ''
code=$(run_under_test)
if [ "$code" = 0 ]; then
    fail "expected non-zero exit"
elif [ "$(get_count /model.pt)" = 0 ]; then
    fail "the script never requested the file"
else
    pass
fi

# 6. A present file of the right size is trusted: no request at all.
start_case 'present file whose size matches expected_bytes -> no second request'
mkdir -p "$WORK/indexed_model/antifold"
head -c 4096 /dev/zero | tr '\0' 'x' > "$WORK/$OUT_REL"
serve_bytes model.pt 4096
write_manifest '["model.pt"]' '{"model.pt":4096}' ''
code=$(run_under_test)
if [ "$code" != 0 ]; then
    fail "expected exit 0, got $code"
elif [ "$(get_count /model.pt)" != 0 ]; then
    fail "expected 0 requests, got $(get_count /model.pt)"
else
    pass
fi

# 7. The upstream bug: skipping on non-empty alone reuses a partial checkpoint forever.
#    A present file of the wrong size must be re-fetched, and a bad re-fetch must fail.
start_case 'present file whose size mismatches -> re-fetched, and a bad re-fetch fails'
mkdir -p "$WORK/indexed_model/antifold"
head -c 100 /dev/zero | tr '\0' 'x' > "$WORK/$OUT_REL"   # partial, non-empty
serve_bytes model.pt 100                                  # upstream still short
write_manifest '["model.pt"]' '{"model.pt":4096}' ''
code=$(run_under_test)
if [ "$code" = 0 ]; then
    fail "expected non-zero exit: neither the present file nor the re-fetch is 4096 bytes"
elif [ "$(get_count /model.pt)" != 1 ]; then
    fail "expected the wrong-size file to be re-fetched, got $(get_count /model.pt) requests"
else
    pass
fi

# 8. A failed download leaves nothing behind that a later build could mistake for
#    a complete checkpoint — no final file, and no leftover .part.
start_case 'failed download leaves no file at the final path and no .part'
serve_bytes model.pt 512
write_manifest '["model.pt"]' '{"model.pt":4096}' ''
code=$(run_under_test)
if [ "$code" = 0 ]; then
    fail "expected non-zero exit"
elif [ -e "$WORK/$OUT_REL" ]; then
    fail "a short download was left at the final path"
elif [ -e "$WORK/$OUT_REL.part" ]; then
    fail "the .part file was not removed"
else
    pass
fi

# 9. An incomplete manifest fails naming the missing field.
start_case 'manifest missing base_url -> non-zero exit naming the field'
serve_bytes model.pt 1024
write_manifest '["model.pt"]' '{"model.pt":1024}' '' OMIT
code=$(run_under_test)
if [ "$code" = 0 ]; then
    fail "expected non-zero exit"
elif ! grep -q 'base_url' "$WORK/stderr.log"; then
    fail "error message does not name base_url"
else
    pass
fi

# 10. An unsizable file is rejected up front, not downloaded and then failed every run.
start_case 'file with no expected_bytes entry -> non-zero exit naming that file'
serve_bytes model.pt 1024
write_manifest '["model.pt"]' '{}' ''
code=$(run_under_test)
if [ "$code" = 0 ]; then
    fail "expected non-zero exit"
elif ! grep -q 'model.pt' "$WORK/stderr.log"; then
    fail "error message does not name model.pt"
elif [ "$(get_count /model.pt)" != 0 ]; then
    fail "the file was downloaded before the manifest was rejected"
else
    pass
fi

# 11. The regression risk in the size-equality skip: a bare stat on a missing path exits
#     non-zero under `set -euo pipefail` and would kill the script before any download,
#     breaking every fresh checkout and CI run. Absent must read as absent.
start_case 'first run against an empty output directory -> the absent file is downloaded'
serve_bytes model.pt 777
write_manifest '["model.pt"]' '{"model.pt":777}' ''
if [ -e "$WORK/indexed_model" ]; then
    fail "precondition broken: indexed_model/ already exists"
else
    code=$(run_under_test)
    if [ "$code" != 0 ]; then
        fail "expected exit 0 on a fresh checkout, got $code"
    elif [ "$(get_count /model.pt)" != 1 ]; then
        fail "expected 1 download, got $(get_count /model.pt)"
    elif [ ! -f "$WORK/$OUT_REL" ]; then
        fail "$OUT_REL missing"
    else
        pass
    fi
fi

# 12. LICENSE-NOTES.md, not LICENSE, is what this asset ships next to the weights.
start_case 'LICENSE-NOTES.md beside the manifest is copied into the asset root'
serve_bytes model.pt 1024
write_manifest '["model.pt"]' '{"model.pt":1024}' ''
echo 'license unresolved' > "$WORK/LICENSE-NOTES.md"
code=$(run_under_test)
if [ "$code" != 0 ]; then
    fail "expected exit 0, got $code"
elif [ ! -f "$WORK/indexed_model/antifold/LICENSE-NOTES.md" ]; then
    fail "LICENSE-NOTES.md did not enter the asset root"
elif grep -q 'no LICENSE' "$WORK/stderr.log"; then
    fail "the script warned about a missing license file that is present"
else
    pass
fi

echo
echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
