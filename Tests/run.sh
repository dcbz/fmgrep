#!/bin/sh
# Smoke tests for fmgrep. Assumes a release (or debug) binary and exercises
# real model calls; expect a few seconds per check.
set -eu
BIN=${BIN:-.build/release/fmgrep}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/config.py" <<'EOF'
# Server configuration
MAX_CONNECTIONS = 250
DATABASE_URL = "postgres://db.internal:5432/app"
keepalive_interval_sec = 30
EOF

cat > "$TMP/notes.txt" <<'EOF'
Meeting notes
- sarah will benchmark the retry policy for the payments gateway
  (exponential backoff, max 5 attempts)
EOF

fail() { echo "FAIL: $1"; exit 1; }

# 1. semantic hit on a file argument
"$BIN" "which database the app uses" "$TMP/config.py" > "$TMP/out1" || fail "expected exit 0"
grep -q DATABASE_URL "$TMP/out1" || fail "expected the DATABASE_URL line"

# 2. clearly-absent query exits 1, silently
if "$BIN" "submarines under antarctic ice" "$TMP/config.py" "$TMP/notes.txt" > "$TMP/out2" 2>/dev/null; then
  [ -s "$TMP/out2" ] && fail "non-matching query produced output"
  fail "non-matching query exited 0"
fi

# 3. -l prints one file name only
"$BIN" -r -l "how payments are retried" "$TMP" | grep -q notes.txt || fail "-l listing"

# 4. stdin works
printf 'the app skips files that are extremely large to read' | "$BIN" "file size limit" > /dev/null || fail "stdin"

# 5. JSONL mode emits parseable objects
"$BIN" --json "database connection" "$TMP/config.py" > "$TMP/out5" || fail "--json"
while read -r l; do echo "$l" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "--json not parseable"; done < "$TMP/out5"

# 6. prefilter skips blocks that cannot match (still finds the hit)
"$BIN" -E 'postgres' "database connection string" "$TMP/config.py" > "$TMP/out6" || fail "-E prefilter"
grep -q DATABASE_URL "$TMP/out6" || fail "-E lost the match"

echo "all smoke tests passed"
