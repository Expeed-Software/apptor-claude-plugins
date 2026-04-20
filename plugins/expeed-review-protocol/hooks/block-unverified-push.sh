#!/usr/bin/env bash
# expeed-review-protocol — PreToolUse(Bash) hook
#
# Intercepts `git push` and `gh pr create` commands. If the review checklist for
# the current branch is missing or incomplete, block with exit code 2.
#
# Exit codes:
#   0  — allow (not a push/PR command, or checklist complete, or protected branch)
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

CMD=""
if command -v python3 >/dev/null 2>&1; then
  CMD="$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Known shapes for PreToolUse(Bash): tool_input.command, params.command, input.command
def get(o, *path):
    for k in path:
        if isinstance(o, dict) and k in o:
            o = o[k]
        else:
            return None
    return o
for path in [("tool_input","command"),("toolInput","command"),("params","command"),("input","command"),("command",)]:
    v = get(d, *path)
    if isinstance(v, str):
        print(v); break
' 2>/dev/null || true)"
fi
if [[ -z "$CMD" ]]; then
  CMD="$HOOK_INPUT"
fi

# ---------- match only push / PR create ----------
# Be generous — catch common variants but do not false-positive on e.g. `git push-origin` aliases
# or `pr-view`. Whole-word matches on the verb.
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
    # Do not gate pushes from protected branches. Those should be blocked by branch
    # protection on the remote, not by this plugin.
    exit 0
    ;;
esac

# Allow `git push` of the review-init / smoke-test commits even before /review-complete.
# Heuristic: if the checklist exists but Final Verdict is not signed, still block.
# We want push-to-share-in-progress to be allowed ONLY via the explicit bypass.

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

# Placeholder text detection — the checklist claims complete but still has
# template markers. Treat as incomplete.
if grep -Eq '<paste output / screenshot link>|<exact command>|<exact steps>|<description>' "$CHECKLIST"; then
  cat >&2 <<EOF
expeed-review-protocol: push BLOCKED

Checklist at $CHECKLIST is marked complete but contains template placeholder
text (e.g. <paste output / screenshot link>). The final verdict cannot stand
on placeholders. Fill in the real evidence or revert the final-verdict ticks.
EOF
  exit 2
fi

exit 0
