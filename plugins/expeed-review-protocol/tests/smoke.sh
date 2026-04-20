#!/usr/bin/env bash
# Integration smoke test for expeed-review-protocol hooks.
#
# Verifies:
#   1. Stop hook exits 2 on a done-claim without a checklist.
#   2. Stop hook exits 0 when the checklist is filled with non-placeholder content.
#   3. PreToolUse hook exits 2 on `git push` without a checklist.
#   4. PreToolUse hook exits 0 on `git push` with a completed checklist.
#   5. Nested branch names (e.g. feature/my/nested) work — mkdir -p covers it.
#   6. Tier 0 with docs-only change does not require smoke-test section.
#
# Exit 0 if all assertions pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY="$PLUGIN_DIR/hooks/verify-review.sh"
PUSH_HOOK="$PLUGIN_DIR/hooks/block-unverified-push.sh"

chmod +x "$VERIFY" "$PUSH_HOOK" 2>/dev/null || true

FAIL=0
PASS=0

assert_exit() {
  local expected="$1"; shift
  local label="$1"; shift
  local actual="$1"; shift
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label (exit=$actual)"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $label (expected exit=$expected, got=$actual)"
    FAIL=$((FAIL+1))
  fi
}

# ---------- set up temp git repo ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q
git config user.email "smoke@test.local"
git config user.name "Smoke Test"
git commit --allow-empty -q -m "initial"
git checkout -q -b feature/my-thing

echo "Temp repo: $TMP"
echo "Plugin: $PLUGIN_DIR"
echo

# ---------- helper: synthesize a transcript file with an assistant message ----------
make_transcript() {
  local text="$1"
  local path="$TMP/transcript-$RANDOM.jsonl"
  # Write one assistant event with content as an array of text blocks.
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$path"
  python3 -c "
import json, sys
evt = {'type':'assistant','message':{'content':[{'type':'text','text':sys.argv[1]}]}}
print(json.dumps(evt))
" "$text" >> "$path"
  printf '%s' "$path"
}

make_stop_payload() {
  local tpath="$1"
  python3 -c "
import json
print(json.dumps({'session_id':'abc','transcript_path':'$tpath','cwd':'$TMP','permission_mode':'default','hook_event_name':'Stop'}))
"
}

make_pretool_payload() {
  local cmd="$1"
  python3 -c "
import json,sys
print(json.dumps({'session_id':'abc','transcript_path':'','cwd':'$TMP','hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':sys.argv[1],'description':'x','timeout':0,'run_in_background':False},'tool_use_id':'t1'}))
" "$cmd"
}

# ---------- Test 1: Stop hook blocks on done-claim without checklist ----------
echo "Test 1: Stop hook blocks on done-claim without checklist"
T1="$(make_transcript 'The work is complete and ready to merge.')"
set +e
make_stop_payload "$T1" | bash "$VERIFY" >/dev/null 2>&1
rc=$?
set -e
assert_exit 2 "Stop hook exits 2 without checklist" "$rc"

# ---------- Test 1b: Stop hook allows non-done-claim messages ----------
echo "Test 1b: Stop hook allows non-done-claim messages"
T1B="$(make_transcript 'Still working on this, will continue after lunch.')"
set +e
make_stop_payload "$T1B" | bash "$VERIFY" >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "Stop hook exits 0 on mid-work message" "$rc"

# ---------- Test 2: Stop hook exits 0 with completed checklist ----------
echo "Test 2: Stop hook exits 0 with filled non-placeholder checklist"
mkdir -p ".claude/reviews/$(dirname feature/my-thing)"
cat > ".claude/reviews/feature/my-thing.md" <<'EOF'
# Review Checklist — feature/my-thing

**Tier:** 1
**Tier rationale:** single-file helper.
**Blast radius:** 1 file changed, 1 module touched, user-facing: no.
**Started:** 2026-04-19

## L1 code review (all tiers)
- [x] Dispatched l1-reviewer
- Findings:
  - Critical: none
  - Important: none
  - Minor: none
- Resolution: no findings.

## Smoke test (all tiers) — EVIDENCE REQUIRED
- Boot command (including prerequisites): `./gradlew run`
- User action performed: `opened /health endpoint`
- Expected observable result: `200 OK with {"status":"UP"}`
- Actual observed result: `got 200 OK and {"status":"UP"} in logs`
- [x] Test passed

## Escape hatches used
- [x] None (default)

## Final verdict
- [x] All required gates passed for declared tier
- [x] Checklist committed
- [x] Ready to ship

Signed: Claude (expeed-review-protocol)
Date: 2026-04-19
EOF

set +e
make_stop_payload "$T1" | bash "$VERIFY" >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "Stop hook exits 0 with completed checklist" "$rc"

# ---------- Test 3: PreToolUse blocks git push without checklist ----------
echo "Test 3: PreToolUse blocks git push without checklist"
rm -f ".claude/reviews/feature/my-thing.md"
set +e
make_pretool_payload "git push origin HEAD" | bash "$PUSH_HOOK" >/dev/null 2>&1
rc=$?
set -e
assert_exit 2 "PreToolUse exits 2 without checklist" "$rc"

# ---------- Test 4: PreToolUse allows git push with completed checklist ----------
echo "Test 4: PreToolUse allows git push with completed checklist"
mkdir -p ".claude/reviews/feature"
cat > ".claude/reviews/feature/my-thing.md" <<'EOF'
# Review Checklist — feature/my-thing

**Tier:** 1
**Tier rationale:** single-file helper.
**Blast radius:** 1 file changed, 1 module touched, user-facing: no.
**Started:** 2026-04-19

## L1 code review (all tiers)
- [x] Dispatched l1-reviewer
- Findings: none.
- Resolution: n/a.

## Smoke test (all tiers) — EVIDENCE REQUIRED
- Boot command (including prerequisites): `./gradlew run`
- User action performed: `opened /health`
- Expected observable result: `200 OK`
- Actual observed result: `200 OK confirmed`
- [x] Test passed

## Final verdict
- [x] All required gates passed for declared tier
- [x] Checklist committed
- [x] Ready to ship

Signed: Claude
Date: 2026-04-19
EOF
set +e
make_pretool_payload "git push origin HEAD" | bash "$PUSH_HOOK" >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "PreToolUse exits 0 with completed checklist" "$rc"

# ---------- Test 4b: PreToolUse ignores non-push commands ----------
echo "Test 4b: PreToolUse ignores non-push commands"
set +e
make_pretool_payload "ls -la" | bash "$PUSH_HOOK" >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "PreToolUse exits 0 on non-push command" "$rc"

# ---------- Test 5: nested branch name works ----------
echo "Test 5: nested branch feature/my/nested works"
git checkout -q -b feature/my/nested
# emulate /review-init: mkdir -p the parent chain before writing
CHECKLIST=".claude/reviews/feature/my/nested.md"
mkdir -p "$(dirname "$CHECKLIST")"
cat > "$CHECKLIST" <<'EOF'
# Review Checklist — feature/my/nested

**Tier:** 1
**Tier rationale:** trivial.
**Blast radius:** 1 file changed, 1 module touched, user-facing: no.
**Started:** 2026-04-19

## L1 code review (all tiers)
- [x] Dispatched l1-reviewer
- Findings: none.
- Resolution: n/a.

## Smoke test (all tiers) — EVIDENCE REQUIRED
- Boot command (including prerequisites): `./gradlew run`
- User action performed: `opened /health`
- Expected observable result: `200 OK`
- Actual observed result: `200 OK confirmed`
- [x] Test passed

## Final verdict
- [x] All required gates passed for declared tier
- [x] Checklist committed
- [x] Ready to ship

Signed: Claude
Date: 2026-04-19
EOF
[[ -f "$CHECKLIST" ]] && echo "  PASS: nested checklist written" && PASS=$((PASS+1)) || { echo "  FAIL: nested checklist write failed"; FAIL=$((FAIL+1)); }
set +e
make_pretool_payload "git push origin HEAD" | bash "$PUSH_HOOK" >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "PreToolUse exits 0 on nested branch with completed checklist" "$rc"

# ---------- Test 6: Tier 0 docs-only doesn't need smoke test ----------
echo "Test 6: Tier 0 checklist without filled smoke-test passes"
git checkout -q -b docs/typo-fix
mkdir -p ".claude/reviews/docs"
cat > ".claude/reviews/docs/typo-fix.md" <<'EOF'
# Review Checklist — docs/typo-fix

**Tier:** 0
**Tier rationale:** docs-only typo fix.
**Blast radius:** 1 file changed, 0 modules touched, user-facing: no.
**Started:** 2026-04-19

## L1 code review (all tiers)
- [x] Dispatched l1-reviewer
- Findings: none.
- Resolution: no findings.

## Smoke test (all tiers) — EVIDENCE REQUIRED
- Boot command (including prerequisites): `N/A - Tier 0`
- User action performed: `N/A - Tier 0`
- Expected observable result: `N/A - Tier 0`
- Actual observed result: `N/A - Tier 0`
- [x] Test passed

## Final verdict
- [x] All required gates passed for declared tier
- [x] Checklist committed
- [x] Ready to ship

Signed: Claude
Date: 2026-04-19
EOF
T6="$(make_transcript 'All done — typo fix ready to ship.')"
set +e
make_stop_payload "$T6" | bash "$VERIFY" >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "Stop hook exits 0 for Tier 0 with N/A smoke sections" "$rc"

echo
echo "============================"
echo "PASS: $PASS    FAIL: $FAIL"
echo "============================"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
exit 0
