#!/usr/bin/env bash
# expeed-review-protocol — Stop hook
#
# Fires when Claude declares a stop. If the last assistant message asserts done /
# complete / ready / approved, verify `.claude/reviews/<branch>.md` exists and
# has the tier-required sections filled with real evidence. Exit 2 blocks.
#
# Exit codes:
#   0  — allow (checklist complete, or not a done-claim, or on a protected branch)
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
# Claude Code passes hook input as JSON on stdin. We want the last assistant
# message text if available. Be resilient: if we can't parse, fall through
# to allow rather than block on infrastructure issues.
HOOK_INPUT=""
if [[ -p /dev/stdin || ! -t 0 ]]; then
  HOOK_INPUT="$(cat 2>/dev/null || true)"
fi

# Extract the last assistant message text. The exact schema varies across
# Claude Code versions; try common paths. If nothing parses, we use the
# raw input as a fallback for the grep.
LAST_MSG=""
if command -v python3 >/dev/null 2>&1; then
  LAST_MSG="$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Try a few known shapes.
def pluck(obj, keys):
    for k in keys:
        if isinstance(obj, dict) and k in obj:
            return obj[k]
    return None
msg = pluck(d, ["last_assistant_message", "lastMessage", "message"])
if isinstance(msg, dict):
    msg = pluck(msg, ["text", "content"])
if isinstance(msg, list):
    # content blocks
    texts = [b.get("text","") for b in msg if isinstance(b, dict)]
    msg = " ".join(texts)
if isinstance(msg, str):
    print(msg)
' 2>/dev/null || true)"
fi
if [[ -z "$LAST_MSG" ]]; then
  LAST_MSG="$HOOK_INPUT"
fi

# ---------- done-claim detection ----------
# Only engage if the assistant's message looks like a completion claim. We want
# to avoid false-positive blocks on mid-work stops.
if ! printf '%s' "$LAST_MSG" | grep -Eiq '(\b(done|complete(d)?|ready|shipped|approved|finished|all set|good to go|merge[- ]ready|ready to ship|ready to merge|ready for review)\b)'; then
  exit 0
fi

# ---------- branch check ----------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
  # Not in a git repo — nothing to gate.
  exit 0
fi
cd "$REPO_ROOT" || exit 0

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$BRANCH" in
  main|master|dev|develop|HEAD|"")
    # Protected / exploratory branches — do not gate.
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
if [[ ! "$TIER" =~ ^[123]$ ]]; then
  cat >&2 <<EOF
expeed-review-protocol: BLOCKED

Checklist at $CHECKLIST does not declare a tier (Tier: 1, 2, or 3).
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

# Smoke test evidence check — this is the gate that actually matters.
# Look for literal placeholders that mean the section was never filled.
if grep -Eq '<paste output / screenshot link>|<exact command>|<exact steps>|<description>' "$CHECKLIST"; then
  cat >&2 <<EOF
expeed-review-protocol: BLOCKED

Checklist at $CHECKLIST still contains placeholder text from the template.
Real evidence is required — the smoke test section must have the actual
boot command, user action, and observed output.

Next step:
  Run /smoke-test to capture real evidence, then /review-complete.

Bypass (emergency only, audited):
  EXPEED_REVIEW_SKIP=1
EOF
  exit 2
fi

# All checks passed.
exit 0
