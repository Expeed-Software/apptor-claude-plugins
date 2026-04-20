#!/usr/bin/env bash
# expeed-review-protocol — PreToolUse(Bash) hook
#
# Intercepts `git push` and `gh pr create` commands. If the review checklist for
# the current branch is missing or incomplete, block with exit code 2.
#
# PreToolUse(Bash) stdin schema (authoritative):
#   { "session_id": "...", "transcript_path": "...", "cwd": "...",
#     "hook_event_name": "PreToolUse", "tool_name": "Bash",
#     "tool_input": { "command": "<cmd>", "description": "...",
#                     "timeout": ..., "run_in_background": ... },
#     "tool_use_id": "..." }
# Command lives at .tool_input.command.
#
# Exit codes:
#   0  — allow (not a push/PR command, or checklist complete, or protected branch,
#              or any infrastructure parse failure — we never block on infra)
#   2  — block with stderr message
#
# Bypass:
#   EXPEED_REVIEW_SKIP=1  — logged to stderr, allow anyway

set -u

# ---------- bypass ----------
if [[ "${EXPEED_REVIEW_SKIP:-0}" == "1" ]]; then
  echo "expeed-review-protocol: push bypass via EXPEED_REVIEW_SKIP=1 (audit)" >&2
  exit 0
fi

# ---------- read hook input & extract command ----------
HOOK_INPUT=""
if [[ -p /dev/stdin || ! -t 0 ]]; then
  HOOK_INPUT="$(cat 2>/dev/null || true)"
fi

# Prefer jq; fall back to python3; fall back to silent-allow.
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  CMD="$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("command",""))
except Exception:
    pass' 2>/dev/null || true)"
fi

# No command parsed — silent allow.
if [[ -z "$CMD" ]]; then exit 0; fi

# ---------- match only push / PR create ----------
if ! printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+push([[:space:]]|$)|(^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
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

CHECKLIST=".claude/reviews/${BRANCH}.md"

if [[ ! -f "$CHECKLIST" ]]; then
  cat >&2 <<EOF
expeed-review-protocol: push BLOCKED

Branch '$BRANCH' has no review checklist at:
  $CHECKLIST

The review protocol gate has not run. You cannot push / open a PR until
a tier-appropriate checklist exists and is marked complete.

Next steps:
  1. Run /review-init to bootstrap the checklist.
  2. Run /smoke-test to capture smoke-test evidence.
  3. Run /review-complete to mark the final verdict.
  4. Retry the push.

Emergency bypass (audited):
  EXPEED_REVIEW_SKIP=1 git push ...
EOF
  exit 2
fi

# Check Final Verdict is signed.
if ! grep -q '^\- \[x\] All required gates passed for declared tier' "$CHECKLIST" \
   || ! grep -q '^\- \[x\] Ready to ship' "$CHECKLIST"; then
  cat >&2 <<EOF
expeed-review-protocol: push BLOCKED

Checklist at $CHECKLIST is not marked complete.

Next step:
  Run /review-complete. It will verify each tier-required section and tell
  you exactly what is missing before the final verdict can be signed.

Emergency bypass (audited):
  EXPEED_REVIEW_SKIP=1 git push ...
EOF
  exit 2
fi

# Placeholder text detection — centralized. Same rule as the Stop hook.
PLACEHOLDER_RE='<(paste output / screenshot link|exact command|exact steps|description|Claude-session-or-human-reviewer|path to committed runbook\.md|log excerpt or link|paste|file:line — problem[^>]*|category \+ file:line[^>]*|list[^>]*|N files changed[^>]*|Critical / Important / Minor[^>]*)>'
if grep -Eq "$PLACEHOLDER_RE" "$CHECKLIST" || grep -qE '^Date:[[:space:]]*YYYY-MM-DD[[:space:]]*$' "$CHECKLIST"; then
  cat >&2 <<EOF
expeed-review-protocol: push BLOCKED

Checklist at $CHECKLIST is marked complete but contains template placeholder
text (e.g. <paste output / screenshot link>, unfilled date). The final verdict
cannot stand on placeholders. Fill in the real evidence or revert the
final-verdict ticks.
EOF
  exit 2
fi

exit 0
