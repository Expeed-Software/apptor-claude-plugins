#!/usr/bin/env bash
# expeed-review-protocol — Stop hook
#
# Fires when Claude declares a stop. If the last assistant message asserts done /
# complete / ready / approved, verify `.claude/reviews/<branch>.md` exists and
# has the tier-required sections filled with real evidence. Exit 2 blocks.
#
# Stop hook stdin schema (authoritative):
#   { "session_id": "...", "transcript_path": "<path>", "cwd": "...",
#     "permission_mode": "...", "hook_event_name": "Stop" }
# The message content is NOT in the payload. To get the last assistant message,
# tail the JSONL transcript at `transcript_path` and extract text from the last
# line whose role/type is "assistant".
#
# Exit codes:
#   0  — allow (checklist complete, or not a done-claim, or on a protected branch,
#              or any infrastructure parse failure — we never block on infra)
#   2  — block with stderr message
#
# Bypass:
#   EXPEED_REVIEW_SKIP=1  — logged to stderr, allow anyway (for emergencies)

set -u

# ---------- bypass ----------
if [[ "${EXPEED_REVIEW_SKIP:-0}" == "1" ]]; then
  echo "expeed-review-protocol: bypass activated via EXPEED_REVIEW_SKIP=1 (audit)" >&2
  exit 0
fi

# ---------- read hook input ----------
HOOK_INPUT=""
if [[ -p /dev/stdin || ! -t 0 ]]; then
  HOOK_INPUT="$(cat 2>/dev/null || true)"
fi

# ---------- extract transcript_path ----------
# Prefer jq; fall back to python3; fall back to silent-allow (we never block on
# infrastructure failure — that would brick the session).
TRANSCRIPT_PATH=""
if command -v jq >/dev/null 2>&1; then
  TRANSCRIPT_PATH="$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  TRANSCRIPT_PATH="$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("transcript_path",""))
except Exception:
    pass' 2>/dev/null || true)"
fi

# No transcript or no parser — silent allow.
if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# ---------- extract last assistant message text from JSONL ----------
# Each line is an event. Look for the most recent line with type/role "assistant"
# and pull text out of .message.content (array of blocks with .text) or .content.
LAST_MSG=""
if command -v jq >/dev/null 2>&1; then
  LAST_MSG="$(tail -n 200 "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -rs '
        [ .[] | select((.type // .role // "") == "assistant") ] | last // empty
        | (.message.content // .content // [])
        | if type=="string" then .
          elif type=="array" then (map(select(.type=="text") | .text) | join(" "))
          else "" end
      ' 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  LAST_MSG="$(tail -n 200 "$TRANSCRIPT_PATH" 2>/dev/null | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if (d.get("type") or d.get("role") or "") == "assistant":
        last = d
if not last:
    sys.exit(0)
msg = last.get("message", last)
content = msg.get("content") if isinstance(msg, dict) else None
if isinstance(content, str):
    print(content)
elif isinstance(content, list):
    parts=[b.get("text","") for b in content if isinstance(b,dict) and b.get("type")=="text"]
    print(" ".join(parts))
' 2>/dev/null || true)"
fi

# If we still have nothing, silent allow.
if [[ -z "$LAST_MSG" ]]; then exit 0; fi

# ---------- done-claim detection ----------
# Narrow set of phrases that strongly indicate a completion assertion. False
# negatives are tolerable — the PreToolUse hook on git push catches the skip.
# False positives (blocking mid-work Stops) are NOT tolerable.
DONE_PHRASES='\b(all done|work is (now )?(complete|done|ready)|feature is (ready|complete|shipped)|implementation is complete|ready to merge|ready to ship|ready to push|safe to merge|safe to ship|good to merge|good to ship|marking (this|it) (done|complete)|task complete|phase complete|plan complete|APPROVED for merge|ready to deploy)\b'
if ! printf '%s' "$LAST_MSG" | grep -Eiq "$DONE_PHRASES"; then
  exit 0
fi

# ---------- branch check ----------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
  exit 0
fi
cd "$REPO_ROOT" || exit 0

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$BRANCH" in
  main|master|dev|develop|HEAD|"")
    exit 0
    ;;
esac

# ---------- checklist verification ----------
CHECKLIST=".claude/reviews/${BRANCH}.md"

if [[ ! -f "$CHECKLIST" ]]; then
  cat >&2 <<EOF
expeed-review-protocol: BLOCKED

Branch '$BRANCH' has no review checklist at:
  $CHECKLIST

You asserted the work is complete. The review protocol requires a tier-appropriate
checklist before that claim can stand.

Next step:
  Run /review-init to create the checklist, then /smoke-test, then /review-complete.

Bypass (emergency only, audited):
  EXPEED_REVIEW_SKIP=1
EOF
  exit 2
fi

# Parse tier.
TIER="$(grep -E '^\*\*Tier:\*\*' "$CHECKLIST" | head -1 | sed -E 's/.*Tier:\*\*[[:space:]]*([0-9]).*/\1/')"
if [[ ! "$TIER" =~ ^[0123]$ ]]; then
  cat >&2 <<EOF
expeed-review-protocol: BLOCKED

Checklist at $CHECKLIST does not declare a tier (Tier: 0, 1, 2, or 3).
Open the file and set the tier, or re-run /review-init.
EOF
  exit 2
fi

# Check Final Verdict is signed.
if ! grep -q '^\- \[x\] All required gates passed for declared tier' "$CHECKLIST" \
   || ! grep -q '^\- \[x\] Checklist committed' "$CHECKLIST" \
   || ! grep -q '^\- \[x\] Ready to ship' "$CHECKLIST"; then
  cat >&2 <<EOF
expeed-review-protocol: BLOCKED

Checklist at $CHECKLIST is not marked complete. The Final Verdict section
has unticked boxes or is missing.

Next step:
  Run /review-complete. It will verify each tier-required section and tell you
  exactly what is missing.

Bypass (emergency only, audited):
  EXPEED_REVIEW_SKIP=1
EOF
  exit 2
fi

# Placeholder detection — centralized. If the checklist still has any of these
# unfilled template markers, block. `YYYY-MM-DD` is checked as a whole-line
# literal because that's the raw template default; once filled with a real date
# the line will differ.
PLACEHOLDER_RE='<(paste output / screenshot link|exact command|exact steps|description|Claude-session-or-human-reviewer|path to committed runbook\.md|log excerpt or link|paste|file:line — problem[^>]*|category \+ file:line[^>]*|list[^>]*|N files changed[^>]*|Critical / Important / Minor[^>]*)>'
if grep -Eq "$PLACEHOLDER_RE" "$CHECKLIST" || grep -qE '^Date:[[:space:]]*YYYY-MM-DD[[:space:]]*$' "$CHECKLIST"; then
  cat >&2 <<EOF
expeed-review-protocol: BLOCKED

Checklist at $CHECKLIST still contains placeholder text from the template.
Real evidence is required — fill in the actual commands, outputs, dates, and
findings. The smoke test section in particular must have real boot command,
user action, and observed output.

Next step:
  Run /smoke-test to capture real evidence, then /review-complete.

Bypass (emergency only, audited):
  EXPEED_REVIEW_SKIP=1
EOF
  exit 2
fi

# All checks passed.
exit 0
